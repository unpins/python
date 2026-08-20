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
  # stdlib share a single zstd ZIP appended by one `withUnpinEmbed` call — the
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
      # `withUnpinEmbed` runtimeStage snippet, so `$__unpin_stage` is the ZIP
      # root and the stdlib ends up in the SAME zstd ZIP as man + aliases (one
      # pack, not a separately-appended archive). The patched zipimport finds
      # os.py, json/__init__.py, … at the root. Arch-agnostic: only .py
      # shuffling + byte scrub. `srcInterp` is the patched interpreter store
      # path (carries lib/python${pyMajor}).
      stdlibStageSh = { srcInterp }: ''
        # --- stage the pure-Python stdlib at the ZIP root ($__unpin_stage) ---
        cp -r "${srcInterp}/lib/python${pyMajor}/." "$__unpin_stage/"
        chmod -R u+w "$__unpin_stage"
        # drop test suites, dev/build artifacts, pip's marker, idle/turtle demos
        rm -rf "$__unpin_stage"/test "$__unpin_stage"/*/test "$__unpin_stage"/*/tests \
               "$__unpin_stage"/idlelib "$__unpin_stage"/turtledemo "$__unpin_stage"/lib2to3/tests \
               "$__unpin_stage"/config-${pyMajor}-* "$__unpin_stage"/site-packages "$__unpin_stage"/EXTERNALLY-MANAGED \
               "$__unpin_stage"/ctypes/macholib/fetch_macholib*
        find "$__unpin_stage" -name '__pycache__' -type d -prune -exec rm -rf {} +

        # unpins: sitecustomize.py at the stdlib root is auto-imported by site.py
        # at startup; it feeds _unpinca's native trust roots (+ embedded Mozilla
        # fallback) into ssl's default context (cadata). No-op if _unpinca absent.
        cp ${./sitecustomize.py} "$__unpin_stage/sitecustomize.py"

        # functional scrub: subprocess hard-codes a store bash as the shell=True
        # fallback; restore the POSIX default so it works anywhere.
        sed -i -E "s#/nix/store/[a-z0-9]{32}-bash[^\"']*/bin/sh#/bin/sh#g" \
          "$__unpin_stage/subprocess.py"
        # blanket cosmetic scrub of any remaining store path in the .py tree
        grep -rlZ '/nix/store/' "$__unpin_stage" --include='*.py' 2>/dev/null \
          | xargs -0 -r sed -i -E "s#/nix/store/[a-z0-9]{32}-[^ '\":]*#/unpin#g"
      '';

      # getpath patches (shared linux/darwin/windows): (1) silence on-disk
      # landmark warnings — the stdlib is embedded, there is no prefix dir; (2)
      # prepend the running executable to sys.path so zipimport reads the stdlib
      # ZIP appended to the binary. Anchors are OS-agnostic and survive the mingw
      # patch's getpath edits.
      getpathPatchSh = ''
        substituteInPlace Modules/getpath.py \
          --replace-fail \
            "pythonpath = config.get('module_search_paths')" \
            "warn = lambda *a, **k: None  # unpins: stdlib is embedded, no on-disk prefix
pythonpath = config.get('module_search_paths')"
        substituteInPlace Modules/getpath.py \
          --replace-fail \
            '    # First add entries from the process environment' \
            '    # unpins: serve stdlib zip appended to the executable itself.
    # `executable` is always defined here (set at module top); `real_executable`
    # is only conditionally assigned, so guard it via globals() to resolve
    # symlink/alias invocations to the real binary when available.
    _u = globals().get("real_executable") or executable
    if _u and _u not in pythonpath:
        pythonpath.append(_u)

    # First add entries from the process environment'
      '';

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
        cp ${./unpinzstd/unpin_zstd.c}       Modules/_unpinzstd/unpin_zstd.c
        cp ${./unpinzstd/unpin_zstd.h}       Modules/_unpinzstd/unpin_zstd.h
        cp ${./unpinzstd/zstddeclib.c}       Modules/_unpinzstd/zstddeclib.c
        # makesetup prepends Modules/ to source paths and resolves quoted includes
        # next to the .c, so unpin_zstd.c finds unpin_zstd.h + zstddeclib.c. The
        # -D applies to the whole module compile: only unpin_zstd.c reads it (to
        # #include zstddeclib.c, decode-only); the glue ignores it.
        printf '%s\n%s\n' '*static*' \
          '_unpinzstd _unpinzstd/unpinzstd_module.c _unpinzstd/unpin_zstd.c -DUNPIN_ZSTD_VENDORED' \
          >> Modules/Setup.local
      '';

      # Teach the frozen zipimport to inflate zstd (ZIP method 93): unpins packs
      # the embedded stdlib as zstd, not deflate. Lib/zipimport.py is frozen into
      # the binary (single-file build, no on-disk Lib/), so this edit must land
      # before the freeze step regenerates Python/frozen_modules/zipimport.h —
      # exactly like the getpath patch. The decode is the _unpinzstd builtin,
      # fed the shared `.unpin/zdict` dictionary the packer trains for cross-file
      # redundancy: that entry is STORED, so _unpin_get_zdict reads it through the
      # plain compress==0 path (no dict, no recursion) and caches it per archive
      # (the TOC is in _zip_directory_cache by the time any method-93 entry is
      # read). Keys use path_sep (zipimport stores native separators). The lazy
      # import mirrors _get_decompress_func so a stray _unpinzstd.py in some zip
      # cannot recurse. Error strings avoid apostrophes to keep the
      # substituteInPlace bash single-quoting clean.
      zipimportPatchSh = ''
        substituteInPlace Lib/zipimport.py --replace-fail \
'def _get_data(archive, toc_entry):' \
'_importing_unpinzstd = False
_unpin_zdict_cache = {}
def _unpin_get_zdict(archive):
    try:
        return _unpin_zdict_cache[archive]
    except KeyError:
        pass
    d = None
    try:
        files = _zip_directory_cache.get(archive)
        if files:
            toc = files.get(".unpin" + path_sep + "zdict")
            if toc is not None:
                d = _get_data(archive, toc)
    except Exception:
        d = None
    _unpin_zdict_cache[archive] = d
    return d
def _unpin_zstd_decompress(archive, raw_data, file_size):
    global _importing_unpinzstd
    if _importing_unpinzstd:
        raise ZipImportError("cannot decompress data; _unpinzstd not available")
    _importing_unpinzstd = True
    try:
        from _unpinzstd import decompress
    except Exception:
        raise ZipImportError("cannot decompress data; zstd not available")
    finally:
        _importing_unpinzstd = False
    return decompress(raw_data, file_size, _unpin_get_zdict(archive))


def _get_data(archive, toc_entry):'
        substituteInPlace Lib/zipimport.py --replace-fail \
'    if compress == 0:
        # data is not compressed
        return raw_data' \
'    if compress == 0:
        # data is not compressed
        return raw_data

    if compress == 93:
        # unpins: zstd-compressed (ZIP method 93), decoded by builtin _unpinzstd,
        # feeding the shared .unpin/zdict dictionary when present.
        return _unpin_zstd_decompress(archive, raw_data, file_size)'
      '';

      # Windows-only configure.ac / source guards. The multiline --replace-fail
      # anchors must match file content that lives at COLUMN 0 (configure.ac
      # directives, header `#ifdef`s), so the embedded lines below are flush
      # left on purpose — that also forces this indented string's min-indent to
      # 0, preserving every embedded line verbatim (the "col-0 trick").
      windowsConfigurePatchSh = ''
        # Link-based configure probes need the Win32 syslibs in $LIBS, but our
        # mingw LIBS block lands late in configure.ac — AFTER both the socket-
        # function probes and the openssl probes. Inject the syslibs at the very
        # start of the library-function checks so every downstream link-test
        # sees them (autoreconfHook regenerates configure).
        substituteInPlace configure.ac --replace-fail \
'# checks for library functions
AC_CHECK_FUNCS([ \' \
'case $host in *-*-mingw*) LIBS="$LIBS -lws2_32 -liphlpapi -lrpcrt4 -lcrypt32 -ladvapi32 -luser32 -lbcrypt -lsecur32 -lgdi32" ;; esac

# checks for library functions
AC_CHECK_FUNCS([ \'
        # AND append the syslibs to OPENSSL_LIBS *after* AX_CHECK_OPENSSL (which
        # resets it to "-lssl -lcrypto"). Static link resolves left-to-right, so
        # syslibs must FOLLOW -lssl/-lcrypto to back-satisfy their
        # __imp_Cert*/__imp_WSA* refs. Also fixes the final _ssl link command and
        # LIBCRYPTO_LIBS (derived from OPENSSL_LIBS downstream).
        substituteInPlace configure.ac --replace-fail \
'# rpath to libssl and libcrypto' \
'case $host in *-*-mingw*) OPENSSL_LIBS="$OPENSSL_LIBS -lws2_32 -lcrypt32 -ladvapi32 -luser32 -lbcrypt -lsecur32 -lgdi32" ;; esac

# rpath to libssl and libcrypto'

        # _ssl's enum_certificates/enum_crls are guarded by `#ifdef _MSC_VER` in
        # both _ssl.c and its clinic header — MSVC-only, so mingw (gcc) skips
        # them, yet ssl.py imports them on win32. They use wincrypt.h which mingw
        # provides → widen to `_WIN32` (matches msys2 0059). Both files contain
        # _MSC_VER ONLY in these guards.
        substituteInPlace Modules/_ssl.c        --replace-fail '_MSC_VER' '_WIN32'
        substituteInPlace Modules/clinic/_ssl.c.h --replace-fail '_MSC_VER' '_WIN32'

        # Socket timeouts: _PyIsSelectable_fd is gated on `#ifdef _MSC_VER`, so
        # mingw fell to the POSIX `fd < FD_SETSIZE` form. Windows SOCKETs are
        # large kernel handles (>= FD_SETSIZE) → returned false → IS_SELECTABLE=0
        # → wait_connect never engaged → BlockingIOError 10035. Any Windows
        # socket is select()-able, so widen to MS_WINDOWS (matches msys2 0040).
        substituteInPlace Include/internal/pycore_fileutils.h --replace-fail \
'/* A routine to check if a file descriptor can be select()-ed. */
#ifdef _MSC_VER' \
'/* A routine to check if a file descriptor can be select()-ed. */
#ifdef MS_WINDOWS'
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

          # libunpinca's macOS backend links Security + CoreFoundation; the
          # unix/linux backend needs no extra libs.
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
                # gdbm's off_map_lookup references malloc late in the link; the
                # engine's whole-program LTO internalizes musl's WEAK `malloc`
                # alias on some arches (riscv64/ppc64le drop it, x86_64/i686
                # keep it) → `ld.lld: undefined symbol: malloc`. Force-keep it —
                # the per-package analog of nix-lib's mega `bitcodeLibcForce`.
                # `-u malloc` is a no-op where malloc is already retained, so
                # x86_64/i686 stay byte-identical. Rides the existing
                # LDFLAGS=-static → straight to the final CPython link.
                map (f: if f == "LDFLAGS=-static"
                        then "LDFLAGS=-static -Wl,-u,malloc"
                        else f)
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
              ++ lib.optionals isDarwin [ ./darwin-cross.patch ];
            postPatch = (old.postPatch or "")
              + unpincaWireSh {
                  buildPython = pkgs.buildPackages.python3;
                  cacert = pkgs.buildPackages.cacert;
                  extraLibs = unpincaLibs;
                }
              + getpathPatchSh
              + unpinzstdWireSh
              + zipimportPatchSh;
          });

          # Step 1: scrubbed binary named `python` (+ its man for withMan), NO
          # stdlib yet. withMan/withAliases append their overlay ZIPs onto this
          # in its own postFixup (before the stdlib append in step 2).
          base = sp.stdenvNoCC.mkDerivation {
            name = "python-base-${suffix}";
            dontUnpack = true;
            nativeBuildInputs = [ pkgs.buildPackages.python3 ];
            buildPhase = ''
              runHook preBuild
              mkdir -p $out/bin
              cp "${interp}/bin/python${pyMajor}" $out/bin/python
              chmod +w $out/bin/python
              python3 ${./scrub_prefix.py} $out/bin/python "${interp}"
              # carry the interpreter's own man so withMan can harvest it
              if [ -d "${interp}/share/man" ]; then
                mkdir -p $out/share
                cp -r "${interp}/share/man" $out/share/man
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
              // { inherit interp; pname = "python"; inherit (interp) version; };
          });
          embed = {
            man = true;
            aliases = aliasList;
            runtimeStage = stdlibStageSh { srcInterp = interp; };
          };
        };

      # ===================== Windows (mingw cross, x86_64) =====================
      # `pkgs` is windowsPkgs (x86_64-linux + cosmo overlay + allowUnsupportedSystem).
      windowsBuild = pkgs:
        let
          lib = pkgs.lib;
          # mingwStaticCross = pkgsCross.mingwW64 + an overlay wrapping stdenv with
          # makeStaticLibraries AND hostPlatform.isStatic=true. Upstream recipes
          # key off isStatic and emit .a-only, so every dep (zlib/bz2/xz/expat/
          # libffi/mpdecimal/openssl/sqlite/ncurses/gcc-runtime) folds into
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
          }).overrideAttrs (old: {
            meta = (old.meta or { }) // { broken = false; };
            # nixpkgs unconditionally adds Fedora's 3.11 mingw patchset when
            # isMinGW; swap it for our 3.13-rebased consolidated patch.
            patches =
              (builtins.filter (p: !isFedoraMingwPatch p) (old.patches or [ ]))
              ++ [ ./mingw-3.13.patch ];
            configureFlags = (old.configureFlags or [ ]) ++ [
              "--disable-shared"
              "MODULE_BUILDTYPE=static"
              "--disable-test-modules"
            ];
            # static ncurses headers decorate the API with __declspec(dllimport)
            # unless NCURSES_STATIC is defined → _curses link sees undefined
            # __imp_* (wattrset, new_panel, …). Define it for every TU.
            NIX_CFLAGS_COMPILE = (old.NIX_CFLAGS_COMPILE or "") + " -DNCURSES_STATIC";
            CONFIG_SITE = "config.site-mingw";
            postPatch = (old.postPatch or "")
              + unpincaWireSh {
                  buildPython = pkgs.buildPackages.python3;
                  cacert = pkgs.buildPackages.cacert;
                  extraLibs = " -lcrypt32";
                }
              + getpathPatchSh
              + unpinzstdWireSh
              + zipimportPatchSh
              + windowsConfigurePatchSh;
            postInstall = ''
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
            aliases = aliasList;
            runtimeStage = stdlibStageSh { srcInterp = windowsPython; };
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
      # engine automatically. Windows (mingw, off-engine) is unaffected.
      engine = "unpin-llvm";
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

      # darwin static is static-except-libSystem (no static libc on macOS); the
      # interpreter links Security + CoreFoundation for libunpinca's keychain
      # backend — both are public /System/Library/Frameworks, already allowed.
      smoke = [ "--version" ];
      smokePattern = "Python ${pyMajor}";
    };
}
