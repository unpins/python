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

      # Teach `zipfile` the same zstd (ZIP method 93) the zipimport patch above
      # teaches the importer. They are NOT the same reader, and that asymmetry
      # was a real hole: zipimport serves `.py` modules, but every NON-.py
      # resource -- the bundled pip wheel, the venv activate scripts, the pydoc
      # CSS, the embedded man pages -- is read through `zipfile`, which
      # `importlib.resources` sits on top of. Without this, 566 of the archive's
      # 618 members raise NotImplementedError("That compression method is not
      # supported") the moment anything reaches for them by name, and
      # `python -m venv` fails outright because ensurepip cannot read its own
      # wheel. The write path is deliberately left alone (see below).
      zipfilePatchSh = ''
        substituteInPlace Lib/zipfile/__init__.py --replace-fail \
'def _check_compression(compression):' \
'UNPIN_ZIP_ZSTD = 93
_unpin_zdict_cache = {}


def _unpin_zdict_for(archive):
    # unpins: the packer trains ONE zstd dictionary per archive and stores it
    # as the STORED member ".unpin/zdict"; frames compressed against it cannot
    # be decoded without it. Reading it opens a second, independent ZipFile on
    # the same path -- a STORED member needs no decompressor, so this cannot
    # recurse back into here.
    try:
        return _unpin_zdict_cache[archive]
    except KeyError:
        pass
    d = None
    if archive:
        try:
            with ZipFile(archive) as zf:
                d = zf.read(".unpin/zdict")
        except Exception:
            d = None
    _unpin_zdict_cache[archive] = d
    return d


class _UnpinZstdDecompressor:
    """unpins: decode ZIP method 93 (zstd) through the builtin _unpinzstd.

    The unpins packer writes one zstd frame per member, so there is nothing to
    stream: buffer the compressed bytes and decode once the last one arrives.
    ZipExtFile only requires .decompress(data) plus .eof -- the same contract
    the LZMADecompressor wrapper above satisfies.
    """

    def __init__(self, zdict=None, compress_size=0, file_size=0):
        self._zdict = zdict
        self._compress_size = compress_size
        self._file_size = file_size
        self._buf = b""
        self.eof = False

    def decompress(self, data):
        self._buf += data
        if len(self._buf) < self._compress_size:
            return b""
        try:
            from _unpinzstd import decompress as _unpin_decompress
        except ImportError:
            raise NotImplementedError(
                "compression type 93 (zstd) needs the _unpinzstd builtin")
        out = _unpin_decompress(self._buf, self._file_size, self._zdict)
        self._buf = b""
        self.eof = True
        return out


def _check_compression(compression):'
        substituteInPlace Lib/zipfile/__init__.py --replace-fail \
'def _get_decompressor(compress_type):
    _check_compression(compress_type)' \
'def _get_decompressor(compress_type, zdict=None, compress_size=0, file_size=0):
    if compress_type == UNPIN_ZIP_ZSTD:
        # unpins: answered BEFORE _check_compression on purpose, so the WRITE
        # path (_get_compressor, ZipFile(mode=w, compression=93)) keeps
        # rejecting method 93 instead of silently storing data uncompressed.
        return _UnpinZstdDecompressor(zdict, compress_size, file_size)
    _check_compression(compress_type)'
        substituteInPlace Lib/zipfile/__init__.py --replace-fail \
'        self._compress_type = zipinfo.compress_type
        self._compress_left = zipinfo.compress_size
        self._left = zipinfo.file_size

        self._decompressor = _get_decompressor(self._compress_type)' \
'        self._compress_type = zipinfo.compress_type
        self._compress_left = zipinfo.compress_size
        self._left = zipinfo.file_size

        # unpins: method 93 needs the archive shared dictionary. Reach the
        # backing path through the _SharedFile wrapper; an archive opened from
        # a bare file object has no name, and then only dict-less frames decode.
        self._unpin_zdict = None
        if self._compress_type == UNPIN_ZIP_ZSTD:
            self._unpin_zdict = _unpin_zdict_for(
                getattr(getattr(fileobj, "_file", None), "name", None))

        self._decompressor = _get_decompressor(
            self._compress_type, self._unpin_zdict,
            zipinfo.compress_size, zipinfo.file_size)'
        substituteInPlace Lib/zipfile/__init__.py --replace-fail \
'            self._decompressor = _get_decompressor(self._compress_type)
            self._eof = False' \
'            self._decompressor = _get_decompressor(
                self._compress_type, self._unpin_zdict,
                self._orig_compress_size, self._orig_file_size)
            self._eof = False'
      '';

      # `venv` installs its activate scripts by walking `venv/scripts` on disk.
      # With the stdlib embedded there IS no such directory, so os.walk() yields
      # nothing, the loop body never runs, and every venv came out with no
      # activate script at all -- no error, exit status 0. Install the same
      # members out of the archive instead. Independent of the zipfile patch
      # above (os.walk is filesystem-only, whatever the compression), but it
      # reads through `zipfile`, so both are needed for a venv to be complete.
      venvPatchSh = ''
        substituteInPlace Lib/venv/__init__.py --replace-fail \
'    def install_scripts(self, context, path):' \
'    def _unpin_install_scripts_from_zip(self, context, path):
        # unpins: install_scripts() for an embedded (zipimport) stdlib. Mirrors
        # the os.walk() loop below -- only the "common" and os.name
        # directories, same destination layout, same variable substitution --
        # but reads the members from the ZIP appended to the executable.
        import zipfile
        archive = getattr(globals().get("__loader__"), "archive", None)
        if not archive:
            return
        prefix = path[len(archive):].strip("/" + os.sep).replace(os.sep, "/")
        binpath = context.bin_path
        with zipfile.ZipFile(archive) as zf:
            for name in zf.namelist():
                if name.endswith("/") or not name.startswith(prefix + "/"):
                    continue
                parts = name[len(prefix) + 1:].split("/")
                if len(parts) < 2 or parts[0] not in ("common", os.name):
                    continue
                dstdir = os.path.join(binpath, *parts[1:-1])
                os.makedirs(dstdir, exist_ok=True)
                dstfile = os.path.join(dstdir, parts[-1])
                data = zf.read(name)
                try:
                    context.script_path = name
                    new_data = (
                        self.replace_variables(data.decode("utf-8"), context)
                            .encode("utf-8")
                    )
                except UnicodeError as e:
                    logger.warning("unable to copy script %r, "
                                   "may be binary: %s", name, e)
                    continue
                with open(dstfile, "wb") as f:
                    f.write(new_data)
                os.chmod(dstfile, 0o644)

    def install_scripts(self, context, path):'
        substituteInPlace Lib/venv/__init__.py --replace-fail \
'            if do_copies:
                for dest, src in copy_sources.items():' \
'            # unpins: CPython ships venvlauncher.exe / venvwlauncher.exe with
            # its Windows INSTALLER, and venv copies them into the new
            # environment. A mingw cross build produces neither, and the
            # directory they are looked up in lives inside the ZIP appended to
            # the executable, so every copy failed, Scripts\\python.exe was never
            # created, and the environment was unusable -- the only sign being
            # two "Unable to copy" warnings on the way past. Fall back to the
            # interpreter itself, which is the right answer for a single-file
            # build anyway: the environment is defined by the pyvenv.cfg next to
            # the executable, and our binary carries its own stdlib wherever it
            # is copied. The pythonw names are dropped: this is a console build,
            # and a second 29 MB copy would buy nothing.
            if not any(os.path.exists(src) for src in copy_sources.values()):
                copy_sources = {
                    dest: context.executable for dest in copy_sources
                    if not os.path.normcase(dest).startswith("pythonw")
                }

            if do_copies:
                for dest, src in copy_sources.items():'
        substituteInPlace Lib/venv/__init__.py --replace-fail \
'        binpath = context.bin_path
        plen = len(path)' \
'        if not os.path.isdir(path):
            # unpins: the stdlib is a ZIP appended to the executable, so
            # venv/scripts is not a directory and the os.walk() below finds
            # nothing -- leaving every venv without its activate scripts,
            # silently and with a zero exit status.
            self._unpin_install_scripts_from_zip(context, path)
            return

        binpath = context.bin_path
        plen = len(path)'
      '';

      # `import ctypes` died outright on the fully static Linux build: the
      # module ends its setup with `pythonapi = PyDLL(None)`, and dlopen(NULL)
      # in static musl always fails, so the OSError escaped and took the whole
      # module with it -- 1 of only 4 stdlib top-level modules that would not
      # import (the other 3 are tkinter/turtle/_ios_support, none of them
      # promised). That is a limit on LOADING shared libraries, which a static
      # binary genuinely cannot do; it is NOT a reason to lose the half of
      # ctypes that is pure computation (Structure, c_int, CFUNCTYPE, sizeof,
      # memmove, cast), which plenty of code uses without ever opening a
      # library. Worse, the failure was an OSError, which code probing for
      # ctypes behind `except ImportError` does not catch -- so an optional
      # dependency turned into a hard crash. Keep the import alive and move the
      # error to the point of use, with a message that says what is going on.
      # Inert everywhere else: Windows takes the `nt` branch and darwin links
      # libSystem dynamically, so dlopen(NULL) succeeds and the except never
      # fires. The `else:`/`if` anchors sit at column 0, hence the flush-left
      # body (the col-0 trick, same as windowsConfigurePatchSh below).
      ctypesPatchSh = ''
        substituteInPlace Lib/ctypes/__init__.py --replace-fail \
'else:
    pythonapi = PyDLL(None)' \
'else:
    try:
        pythonapi = PyDLL(None)
    except OSError:
        # unpins: static build -- no dynamic loader, so there is no handle to
        # the running program. Defer the error to whoever actually asks.
        class _UnpinNoDynamicLoader:
            def __getattr__(self, name):
                raise OSError(
                    "ctypes.pythonapi is unavailable: this is a statically "
                    "linked build with no dynamic loader")

        pythonapi = _UnpinNoDynamicLoader()'
      '';

      # `importlib.resources.as_file()` threw away the resource NAME. For a
      # member of a real directory `as_file` hands back the file itself, but
      # for one inside a ZIP it has to materialise a copy, and it did that with
      # `mkstemp(suffix=path.name)` -- so the bundled pip wheel arrived as
      # `tmpljoqmi3vpip-26.0.1-py3-none-any.whl`. Every consumer that parses a
      # name back into meaning then reads the wrong thing: `ensurepip.version()`
      # answered `tmptest0g_cpip`, and pip, handed `--find-links` on that
      # directory, saw a distribution called `tmpljoqmi3vpip` and reported
      # `No matching distribution found for pip` -- which is what actually made
      # `python -m venv` fail, even once zipfile could read the member. A
      # private directory gives the same collision safety with the name intact.
      # Only reached for non-filesystem resources (as_file dispatches real
      # paths to themselves), i.e. exactly the embedded-stdlib case.
      resourcesPatchSh = ''
        substituteInPlace Lib/importlib/resources/_common.py --replace-fail \
'def _temp_file(path):
    return _tempfile(path.read_bytes, suffix=path.name)' \
'@contextlib.contextmanager
def _unpin_named_tempfile(
    reader,
    name,
    # gh-93353: keep references for late Python finalization, as _tempfile does.
    *,
    _os_remove=os.remove,
    _os_rmdir=os.rmdir,
):
    # unpins: materialise the resource under its REAL name inside a private
    # directory, instead of mkstemp(suffix=name) which prepends tmpXXXXXX.
    d = tempfile.mkdtemp()
    raw_path = os.path.join(d, name)
    try:
        with open(raw_path, "wb") as f:
            f.write(reader())
        del reader
        yield pathlib.Path(raw_path)
    finally:
        try:
            _os_remove(raw_path)
        except FileNotFoundError:
            pass
        try:
            _os_rmdir(d)
        except OSError:
            pass


def _temp_file(path):
    name = os.path.basename(path.name or "")
    if not name or name in (os.curdir, os.pardir):
        return _tempfile(path.read_bytes, suffix=path.name)
    return _unpin_named_tempfile(path.read_bytes, name)'
      '';

      # Wire libunpinca into `ssl` itself, so a `python` that never opens a TLS
      # connection never pays for it. This used to live in a `sitecustomize.py`
      # at the stdlib root, which site.py imports at EVERY interpreter startup:
      # it pulled in `re` and `ssl` eagerly and cost **291 ms of a 358 ms
      # `python -c pass`** -- the same run takes 47 ms with `-S`. Startup is
      # most of what a CLI interpreter does, and nothing about feeding trust
      # roots to `ssl` has to happen before `ssl` exists. The roots are now
      # computed lazily, on the first context that actually asks for defaults,
      # and the PEM scan uses str.find instead of `re` so nothing drags that
      # module in either.
      sslPatchSh = ''
        substituteInPlace Lib/ssl.py --replace-fail \
'    def load_default_certs(self, purpose=Purpose.SERVER_AUTH):
        if not isinstance(purpose, _ASN1Object):
            raise TypeError(purpose)
        if sys.platform == "win32":
            for storename in self._windows_cert_stores:
                self._load_windows_store_certs(storename, purpose)
        self.set_default_verify_paths()' \
'    # unpins: False = not computed yet, None = no native roots available.
    _unpin_pem = False

    def _unpin_default_pem(self):
        # unpins: the platform live trust roots (macOS Keychain, Windows ROOT
        # store, Linux system bundle) plus the embedded Mozilla fallback, from
        # the builtin _unpinca. Computed once, on the first context that asks.
        if SSLContext._unpin_pem is not False:
            return SSLContext._unpin_pem
        SSLContext._unpin_pem = None
        try:
            import _unpinca
            if sys.platform == "win32":
                # Windows ships few roots and fetches the rest on demand via
                # Automatic Root Update, which OpenSSL never triggers -- and a
                # sparse but non-empty store would suppress the fallback. Union
                # the live store (it honours enterprise roots) with the
                # fallback so public sites verify either way.
                parts = []
                native = _unpinca.native_pem()
                if native:
                    parts.append(native)
                parts.append(_unpinca.fallback_pem())
                src = "\n".join(parts)
            else:
                # SSL_CERT_FILE / SSL_CERT_DIR precedence lives inside
                # libunpinca: when either is set the env wins and the platform
                # store is skipped, so this already reflects the override.
                src = _unpinca.roots_pem()
        except Exception:
            return None
        # load_verify_locations(cadata=str) demands pure ASCII, and CA bundles
        # carry non-ASCII friendly-name labels between the blocks. Keep only
        # the base64 blocks, which are ASCII by definition.
        blocks = []
        begin = "-----BEGIN CERTIFICATE-----"
        end = "-----END CERTIFICATE-----"
        i = 0
        while True:
            a = src.find(begin, i)
            if a < 0:
                break
            b = src.find(end, a)
            if b < 0:
                break
            b += len(end)
            blocks.append(src[a:b])
            i = b
        if blocks:
            SSLContext._unpin_pem = "\n".join(blocks) + "\n"
        return SSLContext._unpin_pem

    def load_default_certs(self, purpose=Purpose.SERVER_AUTH):
        if not isinstance(purpose, _ASN1Object):
            raise TypeError(purpose)
        pem = self._unpin_default_pem()
        if pem:
            try:
                self.load_verify_locations(cadata=pem)
                return
            except Exception:
                pass
        if sys.platform == "win32":
            for storename in self._windows_cert_stores:
                self._load_windows_store_certs(storename, purpose)
        self.set_default_verify_paths()'
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
              ++ lib.optionals isDarwin [ ./darwin-cross.patch ];
            postPatch = (old.postPatch or "")
              + unpincaWireSh {
                  buildPython = pkgs.buildPackages.python3;
                  cacert = pkgs.buildPackages.cacert;
                  extraLibs = unpincaLibs;
                }
              + getpathPatchSh
              + unpinzstdWireSh
              + zipimportPatchSh
              + zipfilePatchSh
              + venvPatchSh
              + ctypesPatchSh
              + resourcesPatchSh
              + sslPatchSh;
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
            runtimeStage = stdlibStageSh { srcInterp = interpDns; };
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
              + zipfilePatchSh
              + venvPatchSh
              + ctypesPatchSh
              + resourcesPatchSh
              + sslPatchSh
              + windowsConfigurePatchSh;
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

      # darwin static is static-except-libSystem (no static libc on macOS); the
      # interpreter links Security + CoreFoundation for libunpinca's keychain
      # backend — both are public /System/Library/Frameworks, already allowed.
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
