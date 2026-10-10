// Minimal CPython bridge for the iOS in-process sidecar.
//
// iOS forbids spawning subprocesses, so instead of running backend/api.py as a
// child we embed python-build-standalone's CPython and run uvicorn on a Python
// thread inside the app (see EmbeddedSidecar.swift). The C API is only reachable
// from the C side here; Swift never touches Python objects directly.
//
// On non-iOS targets these are no-op stubs so the file can live in shared
// sources without dragging Python headers into the macOS build.

#include <TargetConditionals.h>
#include <stdio.h>

#if TARGET_OS_IOS
#include <Python.h>
#endif

// Initialise the interpreter with the embedded stdlib (PYTHONHOME/PYTHONPATH
// are set by the caller before this runs). Returns 0 on success.
//
// Uses PyConfig / Py_InitializeFromConfig (Python 3.8+) instead of the
// deprecated Py_InitializeEx; the old API silently skips some initialisation
// steps on BeeWare's iOS build and leaves __main__ inaccessible.
int ost_python_init(void) {
#if TARGET_OS_IOS
    PyConfig config;
    PyConfig_InitPythonConfig(&config);
    // Read PYTHONHOME / PYTHONPATH from the environment variables already set
    // by EmbeddedSidecar.start() before this function is called.
    config.use_environment = 1;
    config.site_import = 1;

    PyStatus status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);

    if (PyStatus_Exception(status)) {
        fprintf(stderr, "GATE c_shim: Py_InitializeFromConfig failed: %s\n",
                status.err_msg ? status.err_msg : "(no message)");
        return -1;
    }
    if (!Py_IsInitialized()) {
        fprintf(stderr, "GATE c_shim: Py_IsInitialized()=false after init\n");
        return -1;
    }

    // Verify the import machinery (__main__) is reachable — a partial init
    // leaves this NULL and causes PyRun_SimpleString to fail silently.
    PyObject *main_module = PyImport_AddModule("__main__");
    if (!main_module) {
        fprintf(stderr, "GATE c_shim: __main__ unavailable after init\n");
        if (PyErr_Occurred()) { PyErr_Print(); PyErr_Clear(); }
        return -1;
    }
    fprintf(stderr, "GATE c_shim: Python initialized OK\n");
    return 0;
#else
    return -1;
#endif
}

// Run a snippet of Python (the sidecar bootstrap) in the interpreter.
// Returns 0 on success; the caller is responsible for a sensible failure path.
int ost_python_run(const char* source) {
#if TARGET_OS_IOS
    if (source == NULL) return -1;
    int rc = PyRun_SimpleString(source);
    if (rc != 0) {
        fprintf(stderr, "GATE c_shim: PyRun_SimpleString failed (rc=%d)\n", rc);
        // PyRun_SimpleString already called PyErr_Print() internally when it
        // set the error; fetch + print again only if the error is still set
        // (e.g. when __main__ was unreachable and PyErr_Print was skipped).
        if (PyErr_Occurred()) {
            PyObject *etype, *evalue, *etb;
            PyErr_Fetch(&etype, &evalue, &etb);
            PyErr_NormalizeException(&etype, &evalue, &etb);
            if (evalue) {
                PyObject *str = PyObject_Str(evalue);
                if (str) {
                    const char *msg = PyUnicode_AsUTF8(str);
                    fprintf(stderr, "GATE c_shim: error: %s\n", msg ? msg : "(unprintable)");
                    Py_DECREF(str);
                }
            }
            Py_XDECREF(etype);
            Py_XDECREF(evalue);
            Py_XDECREF(etb);
        }
    } else {
        // Bootstrap launched the uvicorn thread — release the GIL so the
        // background Python threads (the asyncio event loop) can actually run.
        // The calling thread never calls back into Python after this point.
        PyEval_SaveThread();
    }
    return rc;
#else
    (void)source;
    return -1;
#endif
}

// Shut the interpreter down. Only meaningful after ost_python_init().
void ost_python_finish(void) {
#if TARGET_OS_IOS
    if (Py_IsInitialized()) Py_Finalize();
#endif
}
