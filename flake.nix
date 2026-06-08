{
  description = "Standalone build of CPython (single self-contained binary, stdlib embedded)";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # CPython normally ships as a binary + a companion `lib/python3.13/` stdlib
  # tree on disk, reached via sys.prefix. unpins ships ONE file: every C
  # extension is folded into the binary as a builtin (MODULE_BUILDTYPE=static),
  # every dependency (zlib/openssl/sqlite/…) is linked statically, and the
  # pure-Python stdlib is packed to a ZIP and appended to the executable.
  # zipimport tolerates the ELF/PE/Mach-O prefix, and a getpath patch prepends
  # the running executable to sys.path, so the binary serves its own stdlib —
  # no companion tree, no PYTHONPATH, no /nix/store refs. This is the Python
  # analog of unpins/perl's @INC-in-the-binary VFS.
  #
  # Embed ordering (critical): `withMan`/`withAliases` each APPEND an overlay
  # ZIP, and so does the stdlib. The unpin metadata reader unions `unpin/*`
  # across every embedded ZIP, but Python's zipimport reads only the LAST
  # End-Of-Central-Directory record. So the stdlib ZIP MUST be appended last:
  #   [ELF/PE/Mach-O][aliases.zip][man.zip][stdlib.zip] + `zip -A`
  # `zip -A` adjusts only the trailing (stdlib) archive's offsets; the man/
  # aliases ZIPs sit in the opaque prefix, located by the reader via their own
  # EOCDs. We therefore do man+aliases embedding ourselves INSIDE the build
  # (so they land before the stdlib) and set `embedMan = false` to stop
  # mkStandaloneFlake from appending a man ZIP after the stdlib.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      pyMajor = "3.13";          # stdlib dir + frozen-getpath version
      aliasList = [ "python3" ]; # unversioned variants only; `python` is binName

      # Shared stdlib staging + scrub + zip, then append to the (already
      # man/alias-embedded) binary as the LAST overlay ZIP. `srcInterp` is the
      # patched interpreter store path (carries lib/python${pyMajor}); `binPath`
      # is the man/alias-embedded binary to append onto; `binName` the output
      # file name (python / python.exe). Arch-agnostic: only .py shuffling +
      # byte scrub, run by the build-host python.
      appendStdlibSh = { srcInterp, scrubAgainst }: ''
        # --- stage + scrub + zip the pure-Python stdlib ---
        cp -r "${srcInterp}/lib/python${pyMajor}" stdlib
        chmod -R u+w stdlib
        # drop test suites, dev/build artifacts, pip's marker, idle/turtle demos
        rm -rf stdlib/test stdlib/*/test stdlib/*/tests \
               stdlib/idlelib stdlib/turtledemo stdlib/lib2to3/tests \
               stdlib/config-${pyMajor}-* stdlib/site-packages stdlib/EXTERNALLY-MANAGED \
               stdlib/ctypes/macholib/fetch_macholib*
        find stdlib -name '__pycache__' -type d -prune -exec rm -rf {} +

        # unpins: sitecustomize.py at the stdlib root is auto-imported by site.py
        # at startup; it feeds _unpinca's native trust roots (+ embedded Mozilla
        # fallback) into ssl's default context (cadata). No-op if _unpinca absent.
        cp ${./sitecustomize.py} stdlib/sitecustomize.py

        # functional scrub: subprocess hard-codes a store bash as the shell=True
        # fallback; restore the POSIX default so it works anywhere.
        sed -i -E "s#/nix/store/[a-z0-9]{32}-bash[^\"']*/bin/sh#/bin/sh#g" \
          stdlib/subprocess.py
        # blanket cosmetic scrub of any remaining store path in the .py tree
        grep -rlZ '/nix/store/' stdlib --include='*.py' 2>/dev/null \
          | xargs -0 -r sed -i -E "s#/nix/store/[a-z0-9]{32}-[^ '\":]*#/unpin#g"

        ( cd stdlib && zip -9 -X -q -r ../python-stdlib.zip . )

        # --- append the stdlib ZIP LAST; zip -A fixes its offsets past the
        #     binary + the man/alias overlay ZIPs that precede it ---
        cat python-stdlib.zip >> "${scrubAgainst}"
        zip -A "${scrubAgainst}" || true
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

          # The patched, fully static interpreter (all C-ext builtin, every dep
          # folded in, getpath serving the embedded stdlib).
          interp = (sp.python3.override {
            ncurses = ncursesFB;
            readline = sp.readline.override { ncurses = ncursesFB; };
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
              else (old.configureFlags or [ ]);
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
              + getpathPatchSh;
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

          withMeta = ulib.withMan pkgs { primary = "python"; }
            (ulib.withAliases pkgs { primary = "python"; aliases = aliasList; } base);
        in
        # Step 2: append the stdlib ZIP last → single self-contained binary.
        sp.stdenvNoCC.mkDerivation {
          name = "python-onefile-${suffix}";
          dontUnpack = true;
          nativeBuildInputs = [ pkgs.buildPackages.zip pkgs.buildPackages.python3 ];
          buildPhase = ''
            runHook preBuild
            mkdir -p $out/bin
            cp "${withMeta}/bin/python" $out/bin/python
            chmod +w $out/bin/python
            ${appendStdlibSh { srcInterp = interp; scrubAgainst = "$out/bin/python"; }}
            runHook postBuild
          '';
          dontStrip = true;
          passthru = { inherit interp; pname = "python"; inherit (interp) version; };
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
          crossW64 = ulib.mingwStaticCross pkgs;
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

          # withMan/withAliases resolve `<primary>.exe` automatically.
          withMeta = ulib.withMan pkgs { primary = "python"; }
            (ulib.withAliases pkgs { primary = "python"; aliases = aliasList; } base);
        in
        pkgs.stdenvNoCC.mkDerivation {
          name = "python-onefile-windows";
          dontUnpack = true;
          nativeBuildInputs = [ pkgs.buildPackages.zip pkgs.buildPackages.python3 ];
          buildPhase = ''
            runHook preBuild
            mkdir -p $out/bin
            cp "${withMeta}/bin/python.exe" $out/bin/python.exe
            chmod +w $out/bin/python.exe
            ${appendStdlibSh { srcInterp = windowsPython; scrubAgainst = "$out/bin/python.exe"; }}
            runHook postBuild
          '';
          dontStrip = true;
          passthru = { pname = "python"; inherit (windowsPython) version; };
        };
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "python";
      pkgsAttr = "python3";
      # Custom onefile build → no upstream meta.license to carry. CPython is
      # under the PSF License (nixpkgs `psfl`, SPDX Python-2.0).
      license = "Python-2.0";

      build = nativeBuild;
      windowsBuild = windowsBuild;

      # Man + aliases are embedded INSIDE the build (before the stdlib ZIP), so
      # disable the post-build man append that would land a ZIP after the stdlib
      # and shadow it from zipimport.
      embedMan = false;

      # darwin static is static-except-libSystem (no static libc on macOS); the
      # interpreter links Security + CoreFoundation for libunpinca's keychain
      # backend — both are public /System/Library/Frameworks, already allowed.
      smoke = [ "--version" ];
      smokePattern = "Python ${pyMajor}";
    };
}
