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

#if TARGET_OS_IOS
#include <Python.h>
#endif

// Initialise the interpreter with the embedded stdlib (PYTHONHOME/PYTHONPATH
// are set by the caller before this runs). Returns 0 on success.
int ost_python_init(void) {
#if TARGET_OS_IOS
    Py_InitializeEx(0);
    if (!Py_IsInitialized()) return -1;
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
    if (PyErr_Occurred()) PyErr_Clear();
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
