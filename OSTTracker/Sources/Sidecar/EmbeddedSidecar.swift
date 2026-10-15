// In-process sidecar bootstrap for iOS. The app sandbox forbids spawning a
// Python subprocess, so the embedded python-build-standalone CPython runs
// backend/api.py (uvicorn) on a Python thread inside the app. The wire
// contract is unchanged; only the readiness signal differs — instead of the
// stdout OSTTRACKER_READY line, the bootstrap writes the same line to a
// handshake file in the app container, which we poll.

#if os(iOS)

import Foundation

@_silgen_name("ost_python_init") nonisolated private func pythonInit() -> Int32
@_silgen_name("ost_python_run") nonisolated private func pythonRun(_ source: UnsafePointer<CChar>) -> Int32
@_silgen_name("ost_python_finish") nonisolated private func pythonFinish()

nonisolated enum EmbeddedSidecar {
    static func start(timeout: Duration = .seconds(30)) async throws -> SidecarHandshake {
        let container = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let handshakeURL = container.appending(path: "sidecar-handshake.txt")
        try? FileManager.default.removeItem(at: handshakeURL)

        let token = "ost-\(UUID().uuidString)"
        setenv("OST_API_TOKEN", token, 1)
        setenv("OST_API_WATCHDOG", "0", 1)          // no parent to watch; the app IS the host
        setenv("OST_TRACKER_HOME", container.path, 1)
        setenv("OST_HANDSHAKE_FILE", handshakeURL.path, 1)

        guard let pythonRoot = pythonRoot() else {
            print("GATE ios_init: pythonRoot nil — Python.framework missing at \(Bundle.main.bundleURL.appending(path: "Frameworks/Python.framework").path(percentEncoded: false))")
            throw SidecarError.exitedBeforeHandshake
        }
        let stdlib = pythonRoot.appending(path: "lib/python3.11")
        let site = pythonRoot.appending(path: "lib/python3.11/site-packages")
        // Bundle root contains the `backend/` and `ost_tracker/` package folders.
        // Adding the root (not the subdirs) lets Python resolve `import backend.api`
        // and `from ost_tracker.db import …` via normal package discovery.
        let resources = Bundle.main.resourceURL ?? pythonRoot

        print("GATE ios_init: pythonRoot=\(pythonRoot.path(percentEncoded: false))")
        print("GATE ios_init: resources=\(resources.path(percentEncoded: false))")
        setenv("PYTHONHOME", pythonRoot.path(percentEncoded: false), 1)
        setenv("PYTHONPATH", [stdlib.path(percentEncoded: false), site.path(percentEncoded: false), resources.path(percentEncoded: false)].joined(separator: ":"), 1)

        let initRC = pythonInit()
        print("GATE ios_init: Py_InitializeEx rc=\(initRC)")
        guard initRC == 0 else { throw SidecarError.exitedBeforeHandshake }

        // BeeWare's Python routes sys.stderr → Apple system log, which
        // xcrun simctl launch --console does not capture. Redirect both
        // streams to a file first so any import traceback is readable.
        let sidecarLogURL = container.appending(path: "sidecar.log")
        try? FileManager.default.removeItem(at: sidecarLogURL)

        let bootstrap = """
        import sys, os, traceback

        # Redirect output to a file — BeeWare sends sys.stderr to Apple
        # system log which is invisible to simctl --console.
        _log = open(os.environ["OST_TRACKER_HOME"] + "/sidecar.log", "w", buffering=1)
        sys.stdout = _log
        sys.stderr = _log

        try:
            print("GATE py_bootstrap: sys.version=" + sys.version.split()[0], flush=True)
            print("GATE py_bootstrap: sys.path=" + repr(sys.path), flush=True)
            print("GATE py_bootstrap: importing socket/threading...", flush=True)
            import socket, threading
            print("GATE py_bootstrap: importing backend.api...", flush=True)
            import backend.api as api
            print("GATE py_bootstrap: importing uvicorn (direct)...", flush=True)
            # Import from submodules directly to avoid uvicorn/__init__.py →
            # uvicorn.main → uvicorn.supervisors → _subprocess → multiprocessing
            # → _multiprocessing (absent from BeeWare's iOS Python build).
            from uvicorn.config import Config as UvicornConfig
            from uvicorn.server import Server as UvicornServer
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(("127.0.0.1", 0))
            sock.listen(128)
            port = sock.getsockname()[1]
            def _run():
                try:
                    UvicornServer(UvicornConfig(api.app, log_level="info", lifespan="on")).run(sockets=[sock])
                except BaseException as _e:
                    print("GATE uvicorn thread CRASHED: " + repr(_e), flush=True)
                    traceback.print_exc()
                    _log.flush()
            threading.Thread(target=_run, daemon=True).start()
            print("GATE py_bootstrap: uvicorn thread started, port=" + str(port), flush=True)
            # Give uvicorn a moment to start accepting connections.
            import time; time.sleep(1.5)
            print("GATE py_bootstrap: writing handshake port=" + str(port), flush=True)
            with open(os.environ["OST_HANDSHAKE_FILE"], "w") as f:
                f.write("OSTTRACKER_READY port=%d token=%s\\n" % (port, os.environ["OST_API_TOKEN"]))
        except BaseException as _exc:
            traceback.print_exc()
            _log.flush()
            raise
        """
        let runRC = pythonRun(bootstrap)
        print("GATE ios_init: PyRun_SimpleString rc=\(runRC)")
        // Emit the sidecar log regardless of outcome — it contains Python tracebacks.
        if let logData = try? Data(contentsOf: sidecarLogURL),
           let logText = String(data: logData, encoding: .utf8), !logText.isEmpty {
            print("GATE ios_init: sidecar.log ↓\n\(logText)")
        }
        guard runRC == 0 else { throw SidecarError.exitedBeforeHandshake }

        // Poll the handshake file (the server may still be binding — the
        // caller's waitUntilHealthy() covers that race).
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: handshakeURL),
               let line = String(data: data, encoding: .utf8),
               line.hasPrefix("OSTTRACKER_READY") {
                return try SidecarHandshakeParser.parse(line)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        throw SidecarError.handshakeTimeout
    }

    /// BeeWare Python.xcframework embeds a full .framework at
    /// <AppBundle>/Frameworks/Python.framework — that root is PYTHONHOME.
    private static func pythonRoot() -> URL? {
        let url = Bundle.main.bundleURL
            .appending(path: "Frameworks/Python.framework", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return url
    }
}

#endif  // os(iOS)
