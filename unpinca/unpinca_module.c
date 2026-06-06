/* _unpinca — a tiny CPython builtin module wrapping libunpinca.
 *
 * Statically linked into the interpreter (Modules/Setup), so it works in a
 * single static binary with no dlopen. Exposes the trust roots as `str` for
 * ssl.SSLContext.load_verify_locations(cadata=...).
 *
 *   _unpinca.roots_pem()    -> PEM str (native store, else embedded fallback)
 *   _unpinca.native_pem()   -> PEM str or None (OS store only)
 *   _unpinca.fallback_pem() -> PEM str (embedded Mozilla bundle)
 */
#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <stdlib.h>

#include "unpinca.h"

static PyObject *wrap(char *(*fn)(void))
{
    char *pem = fn();
    if (!pem)
        Py_RETURN_NONE;
    PyObject *s = PyUnicode_DecodeASCII(pem, (Py_ssize_t)strlen(pem), "replace");
    free(pem);
    return s;
}

static PyObject *m_roots(PyObject *self, PyObject *args)
{
    (void)self;
    (void)args;
    return wrap(unpin_ca_roots_pem);
}
static PyObject *m_native(PyObject *self, PyObject *args)
{
    (void)self;
    (void)args;
    return wrap(unpin_ca_native_pem);
}
static PyObject *m_fallback(PyObject *self, PyObject *args)
{
    (void)self;
    (void)args;
    return wrap(unpin_ca_fallback_pem);
}

static PyMethodDef methods[] = {
    { "roots_pem", m_roots, METH_NOARGS,
      "Trust roots as PEM: native OS store, else embedded fallback." },
    { "native_pem", m_native, METH_NOARGS,
      "OS trust store as PEM, or None if unavailable." },
    { "fallback_pem", m_fallback, METH_NOARGS,
      "Embedded Mozilla CA bundle as PEM." },
    { NULL, NULL, 0, NULL },
};

static struct PyModuleDef moduledef = {
    PyModuleDef_HEAD_INIT, "_unpinca",
    "Native platform trust roots (libunpinca).", -1, methods,
    NULL, NULL, NULL, NULL,
};

PyMODINIT_FUNC PyInit__unpinca(void)
{
    return PyModule_Create(&moduledef);
}
