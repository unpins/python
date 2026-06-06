# unpins: make ssl use the platform's live trust roots by default.
#
# Runs at interpreter startup. Feeds libunpinca's roots (native OS store, else
# embedded Mozilla fallback) into every default-configured SSLContext via
# cadata. This is the in-process, single-binary analog of curl's --with-ca-embed
# — no temp file, no shell wrapper. On Linux it mirrors the openssl default; on
# Windows it mirrors CPython's own store load; its real value is macOS, where
# openssl otherwise ignores the Keychain.
try:
    import sys as _sys
    import re as _re
    import ssl as _ssl
    import _unpinca as _uc
    if _sys.platform == "win32":
        # Windows: CPython's own load_default_certs already reads the ROOT store,
        # but it is frequently sparse — Windows ships few roots and fetches the
        # rest on demand via Automatic Root Update, which ssl/OpenSSL never
        # triggers, so a never-before-seen issuer fails to verify. Union the live
        # store (native_pem, honours enterprise/custom roots) with the embedded
        # Mozilla fallback so public sites verify regardless. (native->fallback
        # alone wouldn't help: a non-empty sparse store suppresses the fallback.)
        _parts = []
        _n = _uc.native_pem()
        if _n:
            _parts.append(_n)
        _parts.append(_uc.fallback_pem())
        _src = "\n".join(_parts)
    else:
        # Linux mirrors the openssl default; macOS's real value is the Keychain
        # (openssl otherwise ignores it). Native store, else embedded fallback.
        _src = _uc.roots_pem()
    # load_verify_locations(cadata=str) requires pure ASCII, but CA bundles
    # (notably the Mozilla fallback) carry non-ASCII friendly-name labels
    # between blocks. Keep only the base64 cert blocks — guaranteed ASCII, and
    # all libunpinca needs to hand ssl. (C consumers like openssl/mbedtls accept
    # the labels, so the lib itself keeps emitting standard PEM.)
    _blocks = _re.findall(
        r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
        _src, _re.S)
    _pem = ("\n".join(_blocks) + "\n") if _blocks else None
except Exception:
    _pem = None

if _pem:
    _orig_load_default = _ssl.SSLContext.load_default_certs

    def _load_default_certs(self, purpose=_ssl.Purpose.SERVER_AUTH):
        # SSL_CERT_FILE/SSL_CERT_DIR precedence is already handled inside
        # libunpinca (env wins, store skipped), so _pem already reflects the
        # user's override when set.
        try:
            self.load_verify_locations(cadata=_pem)
        except Exception:
            _orig_load_default(self, purpose)

    _ssl.SSLContext.load_default_certs = _load_default_certs
