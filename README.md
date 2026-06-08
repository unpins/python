# python

[CPython](https://www.python.org/) — the interpreter and its entire standard library in a single self-contained binary, built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/python/actions/workflows/python.yml/badge.svg)](https://github.com/unpins/python/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install python`.

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

HTTPS works with no `certifi` and no `SSL_CERT_FILE`: the binary reads the platform's live trust roots (macOS Keychain, Windows ROOT store, or the Linux system bundle) and falls back to an embedded Mozilla CA set. `SSL_CERT_FILE` / `SSL_CERT_DIR` still override when set.

## Build notes

- **One file, no data archive.** The stdlib is a ZIP appended to the executable and served via `zipimport` (no `lib/python3.13/` tree, no `PYTHONPATH`, no `/nix/store` refs). Every C extension is a builtin and every dependency (OpenSSL, SQLite, libffi, ncurses/readline, …) is linked statically.
- **Batteries included.** `ssl`/`hashlib`, `sqlite3`, `ctypes`, `curses`/`readline` (terminfo baked in), `zlib`/`bz2`/`lzma`, `decimal`, sockets with working timeouts.
- **Packages go in a venv.** The embedded stdlib is read-only, so `python -m pip` won't install into the binary — but `ensurepip` + a bundled pip wheel are embedded, so `python -m venv env` gives a venv with a working `pip`.
- **Platforms.** macOS is static-except-`libSystem` (Keychain trust via the public `Security`/`CoreFoundation` frameworks); Windows is a mingw single `.exe` importing only system DLLs (ROOT-store trust via `crypt32`).
