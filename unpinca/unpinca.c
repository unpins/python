/* libunpinca implementation. See unpinca.h.
 *
 * Path lists and precedence are lifted from the openssl-probe and
 * rustls-native-certs crates (the de-facto cross-distro reference, themselves
 * derived from Go's crypto/x509). Precedence (rustls-native-certs):
 *   - if SSL_CERT_FILE and/or SSL_CERT_DIR are set, load ONLY from those and
 *     never touch the platform store (true on every OS);
 *   - otherwise use the platform-native store (Keychain / crypt32 / the distro
 *     bundle file or hashed cert dir);
 *   - unpin_ca_roots_pem() then falls back to the embedded Mozilla bundle only
 *     if all of the above came up empty.
 */
#include "unpinca.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <dirent.h>

/* Embedded Mozilla fallback bundle. Provided at link time by a generated
 * translation unit (data + length), so it drops into any build system without
 * an assembly/incbin step — including CPython's Modules/Setup. */
extern const unsigned char unpin_ca_fallback_data[];
extern const unsigned int unpin_ca_fallback_len;

#ifdef _WIN32
#define UNPIN_PATH_SEP ';'
#else
#define UNPIN_PATH_SEP ':'
#endif

/* ------------------------------------------------- PEM byte accumulator --- */
static int grow(char **buf, size_t *cap, size_t need)
{
    if (need <= *cap)
        return 0;
    size_t ncap = *cap ? *cap * 2 : 16384;
    while (ncap < need)
        ncap *= 2;
    char *n = (char *)realloc(*buf, ncap);
    if (!n)
        return -1;
    *buf = n;
    *cap = ncap;
    return 0;
}

static void put(char **buf, size_t *len, size_t *cap, const char *s, size_t n)
{
    if (grow(buf, cap, *len + n + 1) != 0)
        return;
    memcpy(*buf + *len, s, n);
    *len += n;
    (*buf)[*len] = '\0';
}

/* Read a whole file into a heap buffer (NUL-terminated). NULL on any error. */
static char *read_file(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f)
        return NULL;
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return NULL;
    }
    long sz = ftell(f);
    if (sz <= 0) {
        fclose(f);
        return NULL;
    }
    rewind(f);
    char *p = (char *)malloc((size_t)sz + 1);
    if (!p) {
        fclose(f);
        return NULL;
    }
    size_t got = fread(p, 1, (size_t)sz, f);
    fclose(f);
    p[got] = '\0';
    if (!got) {
        free(p);
        return NULL;
    }
    return p;
}

/* Append a file's bytes to the accumulator if it looks like PEM. */
static void append_file_if_pem(const char *path, char **buf, size_t *len,
                               size_t *cap)
{
    char *c = read_file(path);
    if (!c)
        return;
    if (strstr(c, "-----BEGIN CERTIFICATE-----")) {
        put(buf, len, cap, c, strlen(c));
        if (*len && (*buf)[*len - 1] != '\n')
            put(buf, len, cap, "\n", 1);
    }
    free(c);
}

/* Concatenate every PEM-looking file in a hashed cert directory (the OpenSSL
 * CApath form: certs as individual <hash>.N files / symlinks). */
static void append_dir_pems(const char *dir, char **buf, size_t *len,
                            size_t *cap)
{
    DIR *d = opendir(dir);
    if (!d)
        return;
    struct dirent *e;
    char path[4096];
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.')
            continue;
        int n = snprintf(path, sizeof(path), "%s/%s", dir, e->d_name);
        if (n > 0 && (size_t)n < sizeof(path))
            append_file_if_pem(path, buf, len, cap);
    }
    closedir(d);
}

/* SSL_CERT_FILE + SSL_CERT_DIR, honoured on every platform. *env_set is 1 if
 * either var is present (so the caller skips the platform store entirely, per
 * rustls-native-certs). Returns the concatenated PEM, or NULL. */
static char *env_pem(int *env_set)
{
    const char *file = getenv("SSL_CERT_FILE");
    const char *dirs = getenv("SSL_CERT_DIR");
    *env_set = (file && *file) || (dirs && *dirs);
    if (!*env_set)
        return NULL;

    char *buf = NULL;
    size_t len = 0, cap = 0;
    if (file && *file)
        append_file_if_pem(file, &buf, &len, &cap);
    if (dirs && *dirs) {
        /* strdup is POSIX, not C11; CPython compiles with strict -std=c11
         * -Werror=implicit-function-declaration, so dup by hand. */
        size_t dl = strlen(dirs);
        char *copy = (char *)malloc(dl + 1);
        if (copy) {
            memcpy(copy, dirs, dl + 1);
            char sep[2] = { UNPIN_PATH_SEP, 0 };
            for (char *tok = strtok(copy, sep); tok; tok = strtok(NULL, sep))
                append_dir_pems(tok, &buf, &len, &cap);
            free(copy);
        }
    }
    return (buf && len) ? buf : (free(buf), NULL);
}

/* ---------------------------------------------------------------- macOS --- */
#if defined(__APPLE__)
#include <Security/Security.h>

/* Append one DER cert as base64 PEM (64-col, BEGIN/END). */
static const char b64[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static void append_der_pem(char **buf, size_t *len, size_t *cap,
                           const unsigned char *der, size_t der_len)
{
    put(buf, len, cap, "-----BEGIN CERTIFICATE-----\n", 28);
    size_t col = 0;
    for (size_t i = 0; i < der_len; i += 3) {
        unsigned long v = (unsigned long)der[i] << 16;
        int rem = (int)(der_len - i);
        if (rem > 1)
            v |= (unsigned long)der[i + 1] << 8;
        if (rem > 2)
            v |= der[i + 2];
        char q[4] = { b64[(v >> 18) & 0x3f], b64[(v >> 12) & 0x3f],
                      rem > 1 ? b64[(v >> 6) & 0x3f] : '=',
                      rem > 2 ? b64[v & 0x3f] : '=' };
        put(buf, len, cap, q, 4);
        if ((col += 4) >= 64) {
            put(buf, len, cap, "\n", 1);
            col = 0;
        }
    }
    if (col)
        put(buf, len, cap, "\n", 1);
    put(buf, len, cap, "-----END CERTIFICATE-----\n", 26);
}

/* Aggregate TLS trust result for a cert in one domain, ported from
 * security-framework's tls_trust_settings_for_certificate:
 *   - error from CopyTrustSettings (errSecItemNotFound, …) -> -1, skip cert;
 *   - empty settings array, or no SSL-applicable definitive dict -> TrustRoot;
 *   - else the first SSL-applicable, non-Unspecified result.
 * (kSec* constants' CFString values equal their names, so CFSTR(...) matches
 * the keys exactly, as the Rust crate does.) */
static int trust_result_for(SecCertificateRef cert, SecTrustSettingsDomain dom)
{
    CFArrayRef settings = NULL;
    if (SecTrustSettingsCopyTrustSettings(cert, dom, &settings) != errSecSuccess
        || !settings) {
        if (settings)
            CFRelease(settings);
        return -1;
    }
    int result = kSecTrustSettingsResultTrustRoot; /* empty/none -> trust root */
    for (CFIndex i = 0, n = CFArrayGetCount(settings); i < n; i++) {
        CFDictionaryRef dict =
            (CFDictionaryRef)CFArrayGetValueAtIndex(settings, i);
        CFStringRef pol = (CFStringRef)CFDictionaryGetValue(
            dict, CFSTR("kSecTrustSettingsPolicyName"));
        if (pol && CFStringCompare(pol, CFSTR("sslServer"), 0) != kCFCompareEqualTo)
            continue; /* non-SSL policy */
        CFNumberRef rn = (CFNumberRef)CFDictionaryGetValue(
            dict, CFSTR("kSecTrustSettingsResult"));
        long long rv = kSecTrustSettingsResultTrustRoot; /* missing key -> root */
        if (rn)
            CFNumberGetValue(rn, kCFNumberLongLongType, &rv);
        if (rv == kSecTrustSettingsResultUnspecified
            || rv == kSecTrustSettingsResultInvalid)
            continue;
        result = (int)rv;
        break;
    }
    CFRelease(settings);
    return result;
}

struct der_entry {
    unsigned char *der;
    size_t len;
    int trusted;
};

static int find_der(const struct der_entry *l, size_t n,
                    const unsigned char *der, size_t len)
{
    for (size_t i = 0; i < n; i++)
        if (l[i].len == len && memcmp(l[i].der, der, len) == 0)
            return (int)i;
    return -1;
}

static char *platform_store_pem(void)
{
    /* User overrides Admin overrides System: collect first-wins by DER. */
    const SecTrustSettingsDomain doms[3] = { kSecTrustSettingsDomainUser,
                                             kSecTrustSettingsDomainAdmin,
                                             kSecTrustSettingsDomainSystem };
    struct der_entry *list = NULL;
    size_t count = 0, cap = 0;
    for (int d = 0; d < 3; d++) {
        CFArrayRef certs = NULL;
        if (SecTrustSettingsCopyCertificates(doms[d], &certs) != errSecSuccess
            || !certs) {
            if (certs)
                CFRelease(certs);
            continue; /* errSecNoTrustSettings -> domain empty */
        }
        for (CFIndex i = 0, n = CFArrayGetCount(certs); i < n; i++) {
            SecCertificateRef cert =
                (SecCertificateRef)CFArrayGetValueAtIndex(certs, i);
            int tr = trust_result_for(cert, doms[d]);
            if (tr < 0)
                continue;
            CFDataRef der = SecCertificateCopyData(cert);
            if (!der)
                continue;
            const unsigned char *b = CFDataGetBytePtr(der);
            size_t len = (size_t)CFDataGetLength(der);
            if (find_der(list, count, b, len) < 0) {
                if (count == cap) {
                    cap = cap ? cap * 2 : 256;
                    struct der_entry *nl =
                        (struct der_entry *)realloc(list, cap * sizeof(*nl));
                    if (nl)
                        list = nl;
                }
                if (count < cap) {
                    list[count].der = (unsigned char *)malloc(len);
                    if (list[count].der) {
                        memcpy(list[count].der, b, len);
                        list[count].len = len;
                        list[count].trusted = tr;
                        count++;
                    }
                }
            }
            CFRelease(der);
        }
        CFRelease(certs);
    }
    char *buf = NULL;
    size_t blen = 0, bcap = 0;
    for (size_t i = 0; i < count; i++) {
        if (list[i].trusted == kSecTrustSettingsResultTrustRoot
            || list[i].trusted == kSecTrustSettingsResultTrustAsRoot)
            append_der_pem(&buf, &blen, &bcap, list[i].der, list[i].len);
        free(list[i].der);
    }
    free(list);
    return (buf && blen) ? buf : (free(buf), NULL);
}

/* -------------------------------------------------------------- Windows --- */
#elif defined(_WIN32)
#include <windows.h>
#include <wincrypt.h>

static const char b64[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static void append_der_pem(char **buf, size_t *len, size_t *cap,
                           const unsigned char *der, size_t der_len)
{
    put(buf, len, cap, "-----BEGIN CERTIFICATE-----\n", 28);
    size_t col = 0;
    for (size_t i = 0; i < der_len; i += 3) {
        unsigned long v = (unsigned long)der[i] << 16;
        int rem = (int)(der_len - i);
        if (rem > 1)
            v |= (unsigned long)der[i + 1] << 8;
        if (rem > 2)
            v |= der[i + 2];
        char q[4] = { b64[(v >> 18) & 0x3f], b64[(v >> 12) & 0x3f],
                      rem > 1 ? b64[(v >> 6) & 0x3f] : '=',
                      rem > 2 ? b64[v & 0x3f] : '=' };
        put(buf, len, cap, q, 4);
        if ((col += 4) >= 64) {
            put(buf, len, cap, "\n", 1);
            col = 0;
        }
    }
    if (col)
        put(buf, len, cap, "\n", 1);
    put(buf, len, cap, "-----END CERTIFICATE-----\n", 26);
}

/* Port of windows.rs usable_for_rustls + is_time_valid: trust the cert if it is
 * currently time-valid and either has no EKU restriction ("good for all uses")
 * or lists the TLS server-auth OID. */
static int usable_for_tls(PCCERT_CONTEXT ctx)
{
    if (CertVerifyTimeValidity(NULL, ctx->pCertInfo) != 0)
        return 0; /* expired or not yet valid */

    DWORD cb = 0;
    if (!CertGetEnhancedKeyUsage(ctx, 0, NULL, &cb)) {
        /* No EKU extension or property -> valid for all uses (ValidUses::All). */
        return GetLastError() == (DWORD)CRYPT_E_NOT_FOUND;
    }
    PCERT_ENHKEY_USAGE usage = (PCERT_ENHKEY_USAGE)malloc(cb);
    if (!usage)
        return 0;
    int ok = 0;
    if (CertGetEnhancedKeyUsage(ctx, 0, usage, &cb)) {
        if (usage->cUsageIdentifier == 0) {
            ok = 1; /* empty EKU set -> all uses */
        } else {
            for (DWORD i = 0; i < usage->cUsageIdentifier; i++)
                if (strcmp(usage->rgpszUsageIdentifier[i],
                           szOID_PKIX_KP_SERVER_AUTH) == 0) {
                    ok = 1;
                    break;
                }
        }
    }
    free(usage);
    return ok;
}

static char *platform_store_pem(void)
{
    /* rustls-native-certs reads the current-user "ROOT" store (which merges
     * local-machine + user roots). */
    HCERTSTORE store = CertOpenSystemStoreA(0, "ROOT");
    if (!store)
        return NULL;
    char *buf = NULL;
    size_t len = 0, cap = 0;
    PCCERT_CONTEXT ctx = NULL;
    while ((ctx = CertEnumCertificatesInStore(store, ctx)) != NULL)
        if (usable_for_tls(ctx))
            append_der_pem(&buf, &len, &cap, ctx->pbCertEncoded,
                           ctx->cbCertEncoded);
    CertCloseStore(store, 0);
    return (buf && len) ? buf : (free(buf), NULL);
}

/* ---------------------------------------------------------- Unix-default --- */
#else
/* Cross-distro bundle files, in probe order (openssl-probe / Go crypto/x509). */
static const char *const cert_files[] = {
    "/etc/ssl/certs/ca-certificates.crt",                /* Debian/Ubuntu/Gentoo/SmartOS */
    "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem", /* CentOS/RHEL 7 */
    "/etc/pki/tls/certs/ca-bundle.crt",                  /* Fedora/RHEL 6 */
    "/etc/ssl/ca-bundle.pem",                            /* OpenSUSE */
    "/etc/pki/tls/cacert.pem",                           /* OpenELEC */
    "/etc/ssl/cert.pem",                                 /* Alpine/OpenBSD */
    "/opt/etc/ssl/certs/ca-certificates.crt",            /* Entware */
    "/etc/ssl/certs/cacert.pem",                         /* OpenHarmony */
    "/usr/local/etc/ssl/cert.pem",                       /* FreeBSD */
    "/usr/local/share/certs/ca-root-nss.crt",            /* DragonFly */
    "/etc/openssl/certs/ca-certificates.crt",            /* NetBSD */
    "/etc/certs/ca-certificates.crt",                    /* Solaris 11.2+/OpenIndiana */
    "/etc/ssl/cacert.pem",                               /* OmniOS */
    "/data/data/com.termux/files/usr/etc/tls/cert.pem",  /* Android/Termux */
    "/boot/system/data/ssl/CARootCertificates.pem",      /* Haiku */
    NULL,
};

/* Hashed cert directories (CApath form), in probe order. */
static const char *const cert_dirs[] = {
    "/etc/ssl/certs",               /* SLES, Debian */
    "/etc/pki/tls/certs",           /* Fedora/RHEL */
    "/etc/openssl/certs",           /* NetBSD */
    "/usr/local/share/certs",       /* FreeBSD */
    "/etc/certs/CA",                /* Illumos/Solaris */
    "/system/etc/security/cacerts", /* Android */
    "/etc/security/certificates",   /* OpenHarmony */
    "/var/ssl/certs",               /* AIX */
    NULL,
};

static char *platform_store_pem(void)
{
    /* A single bundle file is the common case and is a complete root set;
     * prefer the first that exists. */
    for (int i = 0; cert_files[i]; i++) {
        char *r = read_file(cert_files[i]);
        if (r && strstr(r, "-----BEGIN CERTIFICATE-----"))
            return r;
        free(r);
    }
    /* No bundle file (SLES/Android style): concat the first existing dir. */
    for (int i = 0; cert_dirs[i]; i++) {
        char *buf = NULL;
        size_t len = 0, cap = 0;
        append_dir_pems(cert_dirs[i], &buf, &len, &cap);
        if (buf && len)
            return buf;
        free(buf);
    }
    return NULL;
}
#endif

/* ----------------------------------------------------------- public API --- */
char *unpin_ca_fallback_pem(void)
{
    size_t n = (size_t)unpin_ca_fallback_len;
    char *p = (char *)malloc(n + 1);
    if (!p)
        return NULL;
    memcpy(p, unpin_ca_fallback_data, n);
    p[n] = '\0';
    return p;
}

char *unpin_ca_native_pem(void)
{
    int env_set = 0;
    char *e = env_pem(&env_set);
    if (env_set)
        return e; /* env override: env-only, never the platform store */
    return platform_store_pem();
}

char *unpin_ca_roots_pem(void)
{
    char *p = unpin_ca_native_pem();
    if (p && *p)
        return p;
    free(p);
    return unpin_ca_fallback_pem();
}
