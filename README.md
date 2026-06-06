# python

Standalone build of [CPython](https://www.python.org/) — the interpreter and its entire standard library in a single self-contained binary.

[![CI](https://github.com/unpins/python/actions/workflows/python.yml/badge.svg)](https://github.com/unpins/python/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) project — native single-binary builds with no third-party runtime dependencies.

## Usage

Run python with [unpin](https://github.com/unpins/unpin):

```bash
unpin python --version
unpin python script.py
unpin python -c 'import ssl, sqlite3, json; print("batteries included")'
```

Installing also adds `python3` as its own command:

```bash
unpin install python
python3 -m http.server 8000
```

Need third-party packages? Spin up a virtual environment — `pip` is bundled, so the venv gets it automatically:

```bash
python -m venv env
env/bin/pip install requests
```

## Build locally

```bash
nix build github:unpins/python
./result/bin/python --version
```

Or run directly:

```bash
nix run github:unpins/python -- -c 'print("hi")'
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/python/releases) page has standalone binaries for manual download.

## TLS / certificates

HTTPS works out of the box with no `certifi`, no `SSL_CERT_FILE`, no system bundle required. The binary reads the platform's live trust roots — the macOS Keychain, the Windows ROOT store, or the system bundle on Linux — and falls back to an embedded Mozilla CA set when the platform store is empty or sparse. `SSL_CERT_FILE` / `SSL_CERT_DIR` still override when set.

## Build notes

- **Single binary, no data archive.** The standard library is packed into the executable as a ZIP and served from it via `zipimport`; the running executable is placed on `sys.path` at startup, so there is no companion `lib/python3.13/` tree, no `PYTHONPATH`, and no `/nix/store` references. Every C extension is compiled in as a builtin (`MODULE_BUILDTYPE=static`) and every dependency (zlib, OpenSSL, SQLite, libffi, expat, mpdecimal, ncurses/readline) is linked statically.
- **Batteries included.** `ssl`/`hashlib` (static OpenSSL 3.x), `sqlite3`, `ctypes`, `curses`, `readline`, `zlib`/`bz2`/`lzma`, `decimal`, `_socket` with working timeouts — all present in the one file. Terminal capabilities for ~35 common terminals are baked in, so `curses`/`readline` render without `/usr/share/terminfo`.
- **Packages go in a venv.** The embedded stdlib is read-only and has no `site-packages`, so `python -m pip` does not work against the binary itself. But `ensurepip` and its bundled pip wheel *are* embedded, so `python -m venv env` creates a normal virtual environment with a working `pip` — `env/bin/pip install <pkg>` then behaves exactly as usual. The binary is an interpreter you build environments against, not one you install into.
- **macOS** is static-except-`libSystem` (macOS has no static libc); the only extra system frameworks are the public `Security` / `CoreFoundation` used for Keychain trust roots.
- **Windows** is cross-built with mingw as a true single `.exe` (deps + gcc runtime folded in, imports only Windows system DLLs); native ROOT-store trust comes from `crypt32`.
