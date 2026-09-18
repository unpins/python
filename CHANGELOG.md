# Changelog

## [Unreleased]

### Changed

- Updated to Python 3.13.15.
- `python` starts about 7× faster: a startup hook wired the system's TLS trust
  roots into `ssl` on every single run, costing 291 ms of a 358 ms start. The
  roots are now read the first time something actually opens a TLS connection.

### Added

- On Linux, `UNPIN_DNS=<server>` now works: on a host whose `/etc/resolv.conf`
  is missing or unreachable — containers, rescue shells, Android — name lookups
  used to fail with no way out. It was meant to be enabled already, but the
  option had no effect on this package.

### Fixed

- `python -m venv` failed instead of creating an environment — the bundled
  `pip` could not be read back out of the binary, and what could be read
  arrived under the wrong name, so `pip` was not recognised as `pip`. Virtual
  environments now get a working `pip`, offline, as documented.
- Virtual environments came out with no `activate` script, on every platform,
  with no error and a zero exit status. On Windows they now also get
  `activate.bat` and `deactivate.bat`, which were never shipped at all.
- Reading a file out of the binary with `zipfile` or `importlib.resources`
  raised `NotImplementedError: That compression method is not supported`. Data
  files shipped inside the standard library are reachable again, and keep their
  real names.
- `import ctypes` failed outright on Linux. A static binary still cannot open
  an external shared library, but the rest of `ctypes` now works and the error,
  when it does come, says why.
