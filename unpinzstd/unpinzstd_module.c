/* _unpinzstd — a tiny CPython builtin that decodes Zstandard frames.
 *
 * Statically linked into the interpreter (Modules/Setup), so it is available
 * at the very start of bootstrap — before any module loads from the appended
 * stdlib ZIP. unpins packs the embedded stdlib as zstd (ZIP method 93); the
 * patched Lib/zipimport.py calls this to inflate each entry. It MUST be a
 * builtin, not an extension on sys.path: zipimport needs it to read the zip it
 * would otherwise load extensions from (chicken/egg), and the very first
 * imports (encodings/codecs/io) come from that zip.
 *
 * The decode-only zstd amalgamation (zstddeclib.c) is folded straight into the
 * binary via unpin_zstd.c's -DUNPIN_ZSTD_VENDORED mode, so there is no runtime
 * libzstd closure.
 *
 *   _unpinzstd.decompress(data, size, dict=None) -> bytes
 *     Inflate `data` (one zstd frame) into exactly `size` bytes. `dict` is an
 *     optional raw zstd dictionary (the shared `.unpin/zdict`); pass None for
 *     self-contained frames. Raises ValueError on any mismatch.
 */
#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include "unpin_zstd.h"

static PyObject *m_decompress(PyObject *self, PyObject *args)
{
    (void)self;
    Py_buffer src;
    Py_ssize_t outsize;
    Py_buffer dict;
    dict.obj = NULL;
    dict.buf = NULL;
    dict.len = 0;

    if (!PyArg_ParseTuple(args, "y*n|z*", &src, &outsize, &dict))
        return NULL;

    if (outsize < 0) {
        PyBuffer_Release(&src);
        if (dict.obj)
            PyBuffer_Release(&dict);
        PyErr_SetString(PyExc_ValueError, "negative output size");
        return NULL;
    }

    PyObject *out = PyBytes_FromStringAndSize(NULL, outsize);
    if (!out) {
        PyBuffer_Release(&src);
        if (dict.obj)
            PyBuffer_Release(&dict);
        return NULL;
    }

    /* The shim holds the dict by reference for the duration of the call; both
     * buffers stay pinned until we release them below. Single-threaded import
     * path, so the process-wide dict slot is safe to set per call and clear. */
    unpin_zstd_set_dict(dict.obj ? dict.buf : NULL,
                        dict.obj ? (size_t)dict.len : 0);
    size_t n = unpin_zstd_decompress(PyBytes_AS_STRING(out), (size_t)outsize,
                                     src.buf, (size_t)src.len);
    unpin_zstd_set_dict(NULL, 0);

    PyBuffer_Release(&src);
    if (dict.obj)
        PyBuffer_Release(&dict);

    if (n != (size_t)outsize) {
        Py_DECREF(out);
        PyErr_SetString(PyExc_ValueError, "zstd decompress failed");
        return NULL;
    }
    return out;
}

static PyMethodDef methods[] = {
    { "decompress", m_decompress, METH_VARARGS,
      "decompress(data, size, dict=None) -> bytes: inflate one zstd frame." },
    { NULL, NULL, 0, NULL },
};

static struct PyModuleDef moduledef = {
    PyModuleDef_HEAD_INIT, "_unpinzstd",
    "Decode Zstandard (ZIP method 93) for the embedded stdlib.", -1, methods,
    NULL, NULL, NULL, NULL,
};

PyMODINIT_FUNC PyInit__unpinzstd(void)
{
    return PyModule_Create(&moduledef);
}
