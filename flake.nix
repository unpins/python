{
  description = "CPython — interpreter and full stdlib in one self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # CPython normally ships as a binary + a companion `lib/python3.13/` stdlib
  # tree on disk, reached via sys.prefix. unpins ships ONE file: every C
  # extension is folded into the binary as a builtin (MODULE_BUILDTYPE=static),
  # every dependency (zlib/openssl/sqlite/…) is linked statically, and the
  # pure-Python stdlib is packed to a zstd ZIP (ZIP method 93) and appended to
  # the executable. zipimport tolerates the ELF/PE/Mach-O prefix; a patched
  # zipimport inflates method 93 via the `_unpinzstd` builtin; and a getpath
  # patch prepends the running executable to sys.path, so the binary serves its
  # own stdlib — no companion tree, no PYTHONPATH, no /nix/store refs. This is
  # the Python analog of unpins/perl's @INC-in-the-binary VFS.
  #
  # ONE embedded ZIP (the catalog norm since the container unification): because
  # the patched zipimport reads zstd, the man pages, aliases, and the entire
  # stdlib share a single zstd ZIP appended by one runtimeEmbed → unpinEmbedWrap — the
  # same machinery vim/perl/biber use. The stdlib lands at the ZIP root (where
  # zipimport finds os.py, json/__init__.py, …); the `unpin/*` metadata sits
  # alongside it (zipimport ignores it; the unpin-vfs reader serves `unpin man`).
  #   [ELF/PE/Mach-O][ man + aliases + stdlib: one zstd ZIP ]
  # The packer trains a shared `.unpin/zdict` dictionary over the tree (stored
  # as a method-0 entry); the patched zipimport loads it to decode the dict-
  # compressed stdlib frames, which buys the cross-file redundancy that per-file
  # zstd cannot. `embedMan = false` (below) stops mkStandaloneFlake appending a
  # SECOND man ZIP — man is already in the one ZIP here.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      pyMajor = "3.13";          # stdlib dir + frozen-getpath version
      aliasList = [ "python3" ]; # unversioned variants only; `python` is binName

      # Stage + scrub the pure-Python stdlib into the embed ZIP root. Run as a
      # runtimeEmbed runtimeStage snippet, so `$__unpin_stage` is the ZIP
      # root and the stdlib ends up in the SAME zstd ZIP as man + aliases (one
      # pack, not a separately-appended archive). The patched zipimport finds
      # os.py, json/__init__.py, … at the root. Arch-agnostic: .py shuffling,
      # byte scrub and bytecode. `srcInterp` is the patched interpreter store
      # path (carries lib/python${pyMajor}); `buildPython` runs on the build host.
      stdlibStageSh = { srcInterp, buildPython, posixShell ? true }: ''
        # --- stage the pure-Python stdlib at the ZIP root ($__unpin_stage) ---
        cp -r "${srcInterp}/lib/python${pyMajor}/." "$__unpin_stage/"
        chmod -R u+w "$__unpin_stage"
        # drop test suites, dev/build artifacts, pip's marker, idle/turtle demos.
        # Two spellings of the build-config dir: `config-3.13-<triple>` on
        # Linux/macOS, plain `config-3.13` on mingw — which is why the Windows
        # binary carried libpython3.13.a (13 MB of it, 63 under the engine) for
        # a build that can never happen: no Python.h ships with it.
        rm -rf "$__unpin_stage"/test "$__unpin_stage"/*/test "$__unpin_stage"/*/tests \
               "$__unpin_stage"/idlelib "$__unpin_stage"/turtledemo "$__unpin_stage"/lib2to3/tests \
               "$__unpin_stage"/config-${pyMajor}-* "$__unpin_stage"/config-${pyMajor} \
               "$__unpin_stage"/site-packages "$__unpin_stage"/EXTERNALLY-MANAGED \
               "$__unpin_stage"/ctypes/macholib/fetch_macholib*
        find "$__unpin_stage" -name '__pycache__' -type d -prune -exec rm -rf {} +

      '' + (if !posixShell then "" else ''
        # functional scrub: subprocess hard-codes a store bash as the shell=True
        # fallback; restore the POSIX default so it works anywhere. Edited here,
        # in the installed tree, because nixpkgs writes that path at build time
        # (not for mingw, whose shell=True goes through cmd.exe).
        grep -qE "/nix/store/[a-z0-9]{32}-bash[^\"']*/bin/sh" "$__unpin_stage/subprocess.py" \
          || { echo "unpins: subprocess.py has no store /bin/sh to restore" >&2; exit 1; }
        sed -i -E "s#/nix/store/[a-z0-9]{32}-bash[^\"']*/bin/sh#/bin/sh#g" \
          "$__unpin_stage/subprocess.py"
      '') + ''
        # Any other store path left in the .py tree (comments, build notes)
        grep -rlZ '/nix/store/' "$__unpin_stage" --include='*.py' 2>/dev/null \
          | xargs -0 -r sed -i -E "s#/nix/store/[a-z0-9]{32}-[^ '\":]*#/unpin#g"

        # Bytecode beside each .py. zipimport cannot write a cache, so without it
        # every run recompiles every module it imports: `import json` 292 ms vs
        # 54 ms. Legacy `foo.pyc` layout (zipimport never looks in __pycache__),
        # unchecked-hash (nothing to validate against in an immutable archive),
        # compiled AFTER the scrub so the .pyc matches the .py it ships with.
        # co_filename is pinned to a fixed prefix (the stage dir is a build temp);
        # the zipimport patch rewrites it to the real path at load. pyc is
        # platform-independent, so the build-host interpreter serves every
        # target -- as long as the minor version (the magic number) matches.
        ${buildPython}/bin/python3 -c \
          'import sys; sys.exit("%d.%d" % sys.version_info[:2] != "${pyMajor}")' \
          || { echo "unpins: build python is not ${pyMajor}" >&2; exit 1; }
        PYTHONHASHSEED=0 ${buildPython}/bin/python3 -m compileall -q -b \
          --invalidation-mode unchecked-hash \
          -s "$__unpin_stage" -p "/unpin/lib/python${pyMajor}" "$__unpin_stage"
      '';

      # Source patches for the embedded stdlib, shared by every target; each
      # carries its reason. They target Lib/ and Modules/getpath.py, which the
      # freeze step bakes into the binary, so they must land before it.
      embedPatches = map (n: ./patches/${n}.patch) [
        "getpath-embedded-stdlib"
        "zipimport-zstd"
        "zipfile-zstd"
        "venv-scripts-from-zip"
        "ctypes-static-pythonapi"
        "resources-as-file-keep-name"
      ];

      # Wire the decode-only zstd amalgamation as the builtin `_unpinzstd`, so the
      # single binary can inflate its zstd-packed stdlib (ZIP method 93) at
      # bootstrap with no runtime libzstd. -DUNPIN_ZSTD_VENDORED folds
      # zstddeclib.c into unpin_zstd.c as one TU (same shim the VFS packer uses);
      # the glue is ~40 lines. Must be a builtin (not a sys.path extension):
      # zipimport needs it to read the very zip extensions would load from, and
      # the first imports (encodings/codecs/io) already come from that zip.
      unpinzstdWireSh = ''
        mkdir -p Modules/_unpinzstd
        cp ${./unpinzstd/unpinzstd_module.c} Modules/_unpinzstd/unpinzstd_module.c
        cp ${ulib.vfsCore + "/unpin_zstd.c"} Modules/_unpinzstd/unpin_zstd.c
        cp ${ulib.vfsCore + "/unpin_zstd.h"} Modules/_unpinzstd/unpin_zstd.h
        cp ${ulib.vfsCore + "/zstddeclib.c"} Modules/_unpinzstd/zstddeclib.c
        # makesetup prepends Modules/ to source paths and resolves quoted includes
        # next to the .c, so unpin_zstd.c finds unpin_zstd.h + zstddeclib.c. The
        # -D applies to the whole module compile: only unpin_zstd.c reads it (to
        # #include zstddeclib.c, decode-only); the glue ignores it.
        printf '%s\n%s\n' '*static*' \
          '_unpinzstd _unpinzstd/unpinzstd_module.c _unpinzstd/unpin_zstd.c -DUNPIN_ZSTD_VENDORED' \
          >> Modules/Setup.local
      '';

      # Wire libunpinca as the builtin `_unpinca` module so the single binary
      # exposes the platform native trust roots + embedded Mozilla fallback to
      # ssl without dlopen. `extraLibs` is the platform link suffix
      # (-framework Security … on darwin, -lcrypt32 on windows, empty on linux).
      unpincaWireSh = { buildPython, cacert, extraLibs }: ''
        mkdir -p Modules/_unpinca
        cp ${./unpinca/unpinca.c}        Modules/_unpinca/unpinca.c
        cp ${./unpinca/unpinca.h}        Modules/_unpinca/unpinca.h
        cp ${./unpinca/unpinca_module.c} Modules/_unpinca/unpinca_module.c
        ${buildPython}/bin/python3 ${./gen_fallback.py} \
          "${cacert}/etc/ssl/certs/ca-bundle.crt" \
          Modules/_unpinca/unpinca_fallback.c
        # makesetup prepends Modules/ to source paths and resolves quoted
        # includes next to the .c, so paths are relative to Modules/.
        printf '%s\n%s\n' '*static*' \
          '_unpinca _unpinca/unpinca_module.c _unpinca/unpinca.c _unpinca/unpinca_fallback.c${extraLibs}' \
          >> Modules/Setup.local
      '';

      # ============ Native (Linux + Darwin) single-file builder ============
      # `pkgs` is the (possibly cross) native pkgs mkStandaloneFlake hands us.
      nativeBuild = pkgs:
        let
          sp = pkgs.pkgsStatic;
          lib = pkgs.lib;
          isDarwin = sp.stdenv.hostPlatform.isDarwin;
          suffix = sp.stdenv.hostPlatform.config;

          # Bake the curated terminfo fallback into libtinfo.a so curses/readline
          # render on hosts without /usr/share/terminfo. Applied to both the
          # _curses ncurses and readline's ncurses.
          ncursesFB = ulib.embedFallbackTerminfo sp.ncurses;

          # libunpinca's macOS backend links Security + CoreFoundation, both
          # public frameworks the darwin gate allows (libSystem stays dynamic:
          # macOS has no static libc).
          unpincaLibs = lib.optionalString isDarwin
            " -framework Security -framework CoreFoundation";

          # sqlite 3.51.2 runs TCL codegen and compiles build-side helper tools
          # (mksourceid/src-verify) DURING its build — both fight the darwin
          # engine, which cannot link a runnable build-host Mach-O executable
          # (the engine cc is crt-less; the plain darwin cc, run inside the
          # engine build env, links through the engine's ELF `ld` shadowing
          # ld64). Linux is unaffected: its build tools are static-musl and run
          # fine, so this whole override is darwin-gated (plain sp.sqlite on
          # linux stays byte-identical). On darwin, four build-only levers, none
          # touching the shipped library (which stays engine bitcode via
          # T.cc = $(CC)):
          #   * --with-tclsh → use the pristine host tclsh for codegen, skipping
          #     the bundled-jimsh build (autosetup returns before its realpath
          #     probe, which would itself hit the linker problem);
          #   * TCLSH_CMD (make-time) → nixpkgs also passes --disable-tcl for
          #     static, which makes sqlite-check-tcl leave TCLSH_CMD=false, so
          #     --with-tclsh alone only clears the configure FATAL — this
          #     supplies the real interpreter to the codegen rule;
          #   * CC_FOR_BUILD → pin B.cc to the plain darwin cc (autosetup would
          #     otherwise force it to the crt-less engine CC on a native build);
          #   * BUILD_CFLAGS -fuse-ld=<cctools ld64> → force the helper-tool link
          #     onto darwin's ld64, bypassing the engine ELF `ld` that shadows it
          #     in the build env (the "neither ET_REL nor LLVM bitcode" failure).
          sqliteBuildCc =
            if !isDarwin then sp.sqlite
            else
              let
                tclsh = "${pkgs.buildPackages.tcl}/bin/tclsh";
                buildCc = "${pkgs.buildPackages.stdenv.cc}/bin/cc";
                ld64 = "${pkgs.buildPackages.stdenv.cc.bintools.bintools}/bin/ld";
              in
              sp.sqlite.overrideAttrs (o: {
                env = (o.env or { }) // {
                  CC_FOR_BUILD = buildCc;
                  BUILD_CFLAGS = "-g -fuse-ld=${ld64}";
                };
                configureFlags = (o.configureFlags or [ ]) ++ [ "--with-tclsh=${tclsh}" ];
                makeFlags = (o.makeFlags or [ ]) ++ [ "TCLSH_CMD=${tclsh}" ];
              });

          # The patched, fully static interpreter (all C-ext builtin, every dep
          # folded in, getpath serving the embedded stdlib).
          interp = (sp.python3.override {
            ncurses = ncursesFB;
            readline = sp.readline.override { ncurses = ncursesFB; };
            sqlite = sqliteBuildCc;
            # The engine already does whole-program LTO (every object is bitcode,
            # lld does the final link). CPython's own `--with-lto` is redundant and
            # its configure demands a standalone `llvm-ar` binary the engine cc
            # doesn't expose (it ships the `llvm` multitool). Turn it off; the
            # engine link is unchanged. enableLTO defaults on for 64-bit
            # linux/darwin, so this matters on every native target.
            enableLTO = false;
            # nixpkgs points zoneinfo's TZPATH and mimetypes' knownfiles at the
            # store (tzdata, mailcap), and the stdlib scrub turns both into
            # `/unpin`: zoneinfo found no time zones. Off, they keep upstream's
            # host paths (/usr/share/zoneinfo…, /etc/mime.types…).
            tzdata = null;
            mimetypesSupport = false;
          }).overrideAttrs (old: {
            # darwin has no static libc, so a full `-static` link fails
            # configure's "C compiler cannot create executables" (why nixpkgs
            # marks pkgsStatic.python3 broken on darwin). Drop just
            # LDFLAGS=-static: MODULE_BUILDTYPE=static still folds every C-ext
            # in, the pkgsStatic deps are .a-only, only libSystem stays dynamic
            # — the catalog's darwin "static" convention. Linux/musl keeps the
            # full -static link.
            configureFlags =
              if isDarwin
              then builtins.filter (f: f != "LDFLAGS=-static") (old.configureFlags or [ ])
              else
                # This branch used to rewrite `LDFLAGS=-static` into
                # `LDFLAGS=-static -Wl,-u,malloc`: gdbm's off_map_lookup
                # references malloc late in the link and the engine's
                # whole-program LTO internalizes musl's WEAK `malloc` alias on
                # some arches (riscv64/ppc64le dropped it, x86_64/i686 kept it)
                # → `ld.lld: undefined symbol: malloc`. nix-lib's engineLd now
                # appends `-u malloc` to every full link on a Linux engine
                # target, so the CPython link gets it without this rewrite.
                (old.configureFlags or [ ]);
            meta = (old.meta or { }) // { broken = false; };
            # CPython's configure refuses to cross-compile to darwin: the
            # cross `case "$host"` arms cover linux/cygwin/ios/wasi/… but not
            # `*-apple-darwin*`, so it falls through to `cross build not
            # supported`. The guard is over-broad — every darwin-specific
            # configure branch keys on `ac_sys_system=Darwin`, not on cross-
            # ness, so darwin cross works exactly like the linux cross that
            # already ships (buildPackages.python3 for codegen + the deps'
            # .a's). The patch adds the two missing `*-apple-darwin*` arms
            # (FreeBSD precedent, see nixpkgs freebsd-cross.patch) and, unlike
            # FreeBSD, also pins a modern `ac_sys_release` so `Darwin/<rel>`
            # version gates (define_xopen_source=no on macOS, the
            # `-undefined dynamic_lookup` LDSHARED arm) match the native path.
            # It targets the generated `configure`, not `configure.ac`: nixpkgs
            # only adds autoreconfHook for non-darwin, so on darwin the shipped
            # `configure` is what actually runs. CI covers x86_64-darwin via the
            # aarch64-darwin→x86_64-darwin cross attr; native aarch64-darwin
            # (macos-14) never takes these arms. Inert on linux, so gate it.
            patches = (old.patches or [ ])
              ++ lib.optionals isDarwin [ ./darwin-cross.patch ]
              ++ embedPatches
              # macOS only: Linux trusts OpenSSL's default lookup, which
              # nix-lib's OpenSSL extends with the distributions' locations and
              # embedded roots; macOS wants the live Keychain.
              ++ lib.optionals isDarwin [ ./patches/ssl-unpinca-roots.patch ];
            postPatch = (old.postPatch or "")
              + lib.optionalString isDarwin (unpincaWireSh {
                  buildPython = pkgs.buildPackages.python3;
                  cacert = pkgs.buildPackages.cacert;
                  extraLibs = unpincaLibs;
                })
              + unpinzstdWireSh;
          });

          # nix-lib's `dnsFallback` option is INERT for this package, and
          # silently so: it appends link flags to the derivation nix-lib builds,
          # and ours links nothing at all -- it copies an interpreter that
          # `sp.python3` already linked, one derivation earlier. Setting the
          # option changed nothing in the binary (no UNPIN_DNS string, no
          # __wrap_getaddrinfo) on the pinned nix-lib AND on HEAD, while curl,
          # also on the engine, carries both. So apply the interposition where
          # the link is, with the flags withDnsFallback itself uses.
          #
          # Why an interpreter wants it: socket, urllib, and everything a user
          # installs into a venv resolve names through this binary, and a static
          # musl build has no NSS -- on a host whose /etc/resolv.conf is missing
          # or unreachable (containers, Android, rescue shells) every lookup is
          # a dead `socket.gaierror: [Errno -3] Try again` with no way out.
          # Measured with the documented method: a mount namespace pointing
          # /etc/resolv.conf at TEST-NET 203.0.113.1, curl as the positive
          # control (000 without the fallback, 200 with).
          #
          # linux-static only. darwin resolves through libSystem and windows
          # through winsock; neither takes this path, and both stay untouched.
          dnsLdFlags =
            "--wrap=getaddrinfo --wrap=freeaddrinfo --wrap=gethostbyname"
            + " -L${ulib.dnsFallbackLib sp}/lib -lunpindns -lc";
          interpDns =
            if isDarwin then interp else ulib.appendLdFlags interp dnsLdFlags;

          # The scrubbed binary named `python` (+ its man), no stdlib: the one
          # ZIP (man + aliases + stdlib) is appended after the build, by
          # runtimeEmbed → unpinEmbedWrap.
          base = sp.stdenvNoCC.mkDerivation {
            name = "python-base-${suffix}";
            dontUnpack = true;
            nativeBuildInputs = [ pkgs.buildPackages.python3 ];
            buildPhase = ''
              runHook preBuild
              mkdir -p $out/bin
              cp "${interpDns}/bin/python${pyMajor}" $out/bin/python
              chmod +w $out/bin/python
              python3 ${./scrub_prefix.py} $out/bin/python "${interpDns}"
              # carry the interpreter's own man so withMan can harvest it
              if [ -d "${interpDns}/share/man" ]; then
                mkdir -p $out/share
                cp -r "${interpDns}/share/man" $out/share/man
              fi
              runHook postBuild
            '';
            dontStrip = true;
          };

        in
        # The PRISTINE scrubbed interpreter base + the embed spec (man + aliases +
        # zstd-packed stdlib). The embed runs once, post-build, via runtimeEmbed →
        # unpinEmbedWrap (the single embed path; man = true overrides embedMan =
        # false). carries `interp`/version passthru for the framework.
        {
          base = base.overrideAttrs (old: {
            name = "python-onefile-${suffix}";
            passthru = (old.passthru or { })
              // { interp = interpDns; pname = "python"; inherit (interp) version; };
          });
          embed = {
            man = true;
            runtimeStage = stdlibStageSh { srcInterp = interpDns; buildPython = pkgs.buildPackages.python3; };
          };
        };

      # ===================== Windows (mingw cross, x86_64) =====================
      # `pkgs` is the engine's Windows set; the interpreter is its mingw cross.
      windowsBuild = pkgs:
        let
          lib = pkgs.lib;
          # mingwStaticCross = pkgsCross.mingwW64 + an overlay wrapping stdenv with
          # makeStaticLibraries AND hostPlatform.isStatic=true. Upstream recipes
          # key off isStatic and emit .a-only, so every dep (zlib/bz2/xz/expat/
          # libffi/mpdecimal/openssl/sqlite/ncurses) folds into
          # python.exe — no per-dep overrides, triple stays x86_64-w64-mingw32.
          # OPENSSLDIR/ENGINESDIR/MODULESDIR default to openssl's own $out, so
          # python.exe carried a live reference to
          # `openssl-…-w64-mingw32-…-etc` -- the directory libcrypto reads the CA
          # trust store from, which `ssl`/`urllib`/`pip` all depend on. The
          # retarget is set-wide ONLY in the engine's native scope
          # (nix-lib/native-overlay/openssl.nix); the mingw scope has none, and
          # openssl/flake.nix:57 covers just the openssl PACKAGE's own .exe.
          # C:/ssl is the value that package uses; unpins/opus-tools and
          # unpins/php needed the same.
          crossW64 = (ulib.mingwStaticCross pkgs).extend (final: prev: {
            openssl = prev.openssl.overrideAttrs (ulib.retargetOpenssl "C:/ssl");
          });
          isFedoraMingwPatch = p: lib.hasInfix "mingw-python" (toString p);

          windowsPython = (crossW64.python3.override {
            # Static openssl (.a only) so _ssl/_hashlib fold libssl/libcrypto in
            # instead of importing libcrypto-3-x64.dll. The Win32 syslibs static
            # openssl needs are added to the global LIBS line by mingw-3.13.patch.
            openssl = crossW64.openssl.override { static = true; };
            # As in `interp`: no store paths for TZPATH and knownfiles.
            tzdata = null;
            mimetypesSupport = false;
          }).overrideAttrs (old: {
            meta = (old.meta or { }) // { broken = false; };
            # nixpkgs unconditionally adds Fedora's 3.11 mingw patchset when
            # isMinGW; swap it for our 3.13-rebased consolidated patch.
            # Then the shared embed patches, and the mingw configure/source
            # guards. No _unpinca: CPython's own Windows path loads the CA and
            # ROOT stores, then OpenSSL's default lookup adds the embedded roots.
            patches =
              (builtins.filter (p: !isFedoraMingwPatch p) (old.patches or [ ]))
              ++ [ ./mingw-3.13.patch ]
              ++ embedPatches
              ++ [ ./patches/mingw-configure-ssl-select.patch ];
            configureFlags = (old.configureFlags or [ ]) ++ [ "--disable-shared" ];
            # static ncurses headers decorate the API with __declspec(dllimport)
            # unless NCURSES_STATIC is defined → _curses link sees undefined
            # __imp_* (wattrset, new_panel, …). Define it for every TU.
            NIX_CFLAGS_COMPILE = (old.NIX_CFLAGS_COMPILE or "") + " -DNCURSES_STATIC";
            CONFIG_SITE = "config.site-mingw";
            postPatch = (old.postPatch or "") + unpinzstdWireSh;
            postInstall = ''
              # CPython's Unix Makefile installs venv/scripts/common and
              # venv/scripts/posix and nothing else -- `nt` is the Windows
              # installer's job, and a mingw cross build never runs it. The
              # Windows binary therefore shipped a venv module that could not
              # produce activate.bat/deactivate.bat for cmd.exe no matter what:
              # the files were simply not there. Install them from the source.
              mkdir -p $out/lib/python${pyMajor}/venv/scripts/nt
              cp Lib/venv/scripts/nt/* $out/lib/python${pyMajor}/venv/scripts/nt/
              # nixpkgs' (!static)-guarded postInstall touches test/__init__.py;
              # our cross build is non-static so it runs, but --disable-test-modules
              # installed no test/ dir. Pre-create it so the touch succeeds.
              mkdir -p $out/lib/python${pyMajor}/test
              # nixpkgs' isWindows postInstall runs `rm $out/bin/2to3*`, but 2to3
              # was removed in 3.13 → the glob matches nothing → rm aborts.
              # Pre-create a stub so rm succeeds (it deletes this).
              mkdir -p $out/bin && touch $out/bin/2to3
            '' + (old.postInstall or "");
          });

          base = pkgs.stdenvNoCC.mkDerivation {
            name = "python-base-windows";
            dontUnpack = true;
            nativeBuildInputs = [ pkgs.buildPackages.python3 ];
            buildPhase = ''
              runHook preBuild
              mkdir -p $out/bin
              cp "${windowsPython}/bin/python${pyMajor}.exe" $out/bin/python.exe
              chmod +w $out/bin/python.exe
              python3 ${./scrub_prefix.py} $out/bin/python.exe "${windowsPython}"
              # The engine compiles with `-g`, and the mingw strip nixpkgs runs
              # over the interpreter leaves the PE's DWARF where it is — 29 MB of
              # it, half the file. Strip it here, where the binary we ship is,
              # with the toolchain that produced it. (nix-lib asserts the result
              # carries no `.debug_*`, so a silent failure cannot ship.)
              ${ulib.llvmMultitool pkgs.stdenv.buildPlatform.system} llvm-strip \
                --strip-debug $out/bin/python.exe
              if [ -d "${windowsPython}/share/man" ]; then
                mkdir -p $out/share
                cp -r "${windowsPython}/share/man" $out/share/man
              fi
              runHook postBuild
            '';
            dontStrip = true;
          };

        in
        # The PRISTINE scrubbed interpreter base + the embed spec; resolves
        # `python.exe` automatically. Embedded post-build via runtimeEmbed.windows.
        {
          base = base.overrideAttrs (old: {
            name = "python-onefile-windows";
            passthru = (old.passthru or { })
              // { pname = "python"; inherit (windowsPython) version; };
          });
          embed = {
            man = true;
            runtimeStage = stdlibStageSh { srcInterp = windowsPython; buildPython = pkgs.buildPackages.python3; posixShell = false; };
          };
        };
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "python";
      pkgsAttr = "python3";
      # Build every C extension + dep closure through the unpin-llvm engine
      # (all objects LLVM bitcode, whole-program LTO). `build`/`windowsBuild`
      # receive an engine-swapped pkgs whose `pkgsStatic` is the bitcode set, so
      # `sp = pkgs.pkgsStatic` in nativeBuild folds the interpreter under the
      # engine automatically.
      engine = "unpin-llvm";
      # python is one program and dispatches nothing; the block is here to put
      # the `.exe` on the engine too, instead of the nixpkgs mingw-gcc cross.
      multicall = {
        windows = true;
        # No bitcode module: every target COPIES the interpreter nixpkgs'
        # python3 built, so this package links nothing and there is no link for
        # the module hook to capture. The engine is wanted for the compiler that
        # builds that interpreter, not for a fold.
        module = false;
        # The aliases belong to the program, not to `runtimeEmbed`: with a
        # `multicall` block the declared list is what the programs say, and a
        # payload that announces a name the flake does not is a hard CI error.
        programs = [{ name = "python"; aliases = aliasList; }];
      };
      # Custom onefile build → no upstream meta.license to carry. CPython is
      # under the PSF License (nixpkgs `psfl`, SPDX Python-2.0).
      license = "Python-2.0";
      # Custom onefile build → no upstream meta.description to carry either.
      description = "CPython interpreter with the entire standard library embedded";

      build = pkgs: (nativeBuild pkgs).base;
      windowsBuild = pkgs: (windowsBuild pkgs).base;
      runtimeEmbed = {
        native = pkgs: _base: (nativeBuild pkgs).embed;
        windows = pkgs: _base: (windowsBuild pkgs).embed;
      };

      # Man + aliases are embedded INSIDE the single ZIP (before the stdlib), so
      # disable the auto man-harvest; runtimeEmbed sets man = true explicitly so
      # everything still lands in ONE pack ahead of the stdlib.
      embedMan = false;

      # The only gate that runs against the FINISHED artifact (the embed happens
      # after `build`, so a `doCheck` here would only ever see the stdlib-less
      # base binary). `--version` alone proved far too weak: it answers before
      # the stdlib is touched, so it stayed green while `zipfile` could not read
      # 566 of the archive's 618 members and `python -m venv` exited 1. This
      # one-liner boots the interpreter, imports through zipimport, reads a
      # member back through `zipfile` (method 93), and builds a real venv with
      # pip -- offline, from the embedded wheel. Single line: action-build feeds
      # each list element as one argv element, but reads them line by line.
      smoke = [
        "-c"
        "import sys,os,ssl,venv,tempfile,zipfile,ensurepip; z=len(zipfile.ZipFile(sys.executable).read(\"json/__init__.py\")); ca=ssl.create_default_context().cert_store_stats()[\"x509_ca\"]; d=tempfile.mkdtemp(); venv.create(d,with_pip=True); b=os.path.join(d,\"Scripts\" if os.name==\"nt\" else \"bin\"); n=[x.lower() for x in os.listdir(b)]; print(\"unpin-smoke\",sys.version.split()[0],\"pip=%d\"%len([x for x in n if x.startswith(\"pip\")]),\"activate=%d\"%len([x for x in n if x.startswith(\"activate\")]),\"zip=%d\"%z,\"ca=%d\"%ca)"
      ];
      smokePattern = "unpin-smoke ${pyMajor}\\.[0-9]+ pip=[1-9][0-9]* activate=[1-9][0-9]* zip=[1-9][0-9]* ca=[1-9][0-9][0-9]";
    };
}
