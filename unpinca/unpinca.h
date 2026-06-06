/* libunpinca — unpins' shared native-trust-roots provider.
 *
 * The C analog of rustls-platform-verifier's roots half: hand back the
 * platform's *live* trust roots so consumers never ship a stale CA set. An
 * embedded Mozilla bundle is the last-resort fallback only (hosts with no
 * system store — scratch containers, minimal images), so embedding can never
 * be the source of truth that goes out of date.
 *
 * All backends link system libraries statically (Security.framework on macOS,
 * crypt32 on Windows, plain file reads on Linux/BSD) — no dlopen, so this is
 * safe inside a fully-static single binary.
 *
 * Currency is a PEM bundle: OpenSSL (load_verify_locations cadata / a memory
 * BIO), mbedtls (mbedtls_x509_crt_parse), and Python's ssl all consume it.
 */
#ifndef UNPINCA_H
#define UNPINCA_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Trusted roots as a heap-allocated, NUL-terminated PEM bundle: the live OS
 * store if available, otherwise the embedded Mozilla fallback. Never NULL
 * unless allocation fails. Caller frees with free(). */
char *unpin_ca_roots_pem(void);

/* OS store only (no fallback). NULL if the platform store is unavailable or
 * empty. Caller frees. Use when you want to distinguish "host has a store"
 * from "we fell back". */
char *unpin_ca_native_pem(void);

/* The embedded Mozilla fallback bundle. Always available. Caller frees. */
char *unpin_ca_fallback_pem(void);

#ifdef __cplusplus
}
#endif

#endif /* UNPINCA_H */
