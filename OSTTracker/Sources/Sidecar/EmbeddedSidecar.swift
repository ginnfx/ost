// In-process sidecar bootstrap for iOS. The app sandbox forbids spawning a
// Python subprocess, so the embedded python-build-standalone CPython runs
// backend/api.py (uvicorn) on a Python thread inside the app. The wire
// contract is unchanged; only the readiness signal differs — instead of the
// stdout OSTTRACKER_READY line, the bootstrap writes the same line to a
// handshake file in the app container, which we poll. See shared/CONTRACT.md.

#if os(iOS)

import Foundation

@_silgen_name("ost_python_init") private func pythonInit() -> Int32
@_silgen_name("ost_python_run") private func pythonRun(_ source: UnsafePointer<CChar>) -> Int32
@_silgen_name("ost_python_finish") private func pythonFinish()

nonisolated enum EmbeddedSidecar {
    static func start(timeout: TimeInterval = 30) async throws -> SidecarHandshake {
        let container = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let handshakeURL = container.appending(path: "sidecar-handshake.txt")
        try? FileManager.default.removeItem(at: handshakeURL)

        let token = "ost-\(UUID().uuidString)"
        setenv("OST_API_TOKEN", token, 1)
        setenv("OST_API_WATCHDOG", "0", 1)          // no parent to watch; the app IS the host
        setenv("OST_TRACKER_HOME", container.path, 1)
        setenv("OST_HANDSHAKE_FILE", handshakeURL.path, 1)

        guard let pythonRoot = pythonRoot() else {
            throw SidecarError.exitedBeforeHandshake
        }
        let stdlib = pythonRoot.appending(path: "lib/python3.11")
        let site = pythonRoot.appending(path: "site-packages")
        let backend = Bundle.main.resourceURL?.appending(path: "backend") ?? pythonRoot
        let domain = Bundle.main.resourceURL?.appending(path: "ost_tracker") ?? pythonRoot

        setenv("PYTHONHOME", pythonRoot.path, 1)
        setenv("PYTHONPATH", [stdlib.path, site.path, backend.path, domain.path].joined(separator: ":"), 1)

        guard pythonInit() == 0 else { throw SidecarError.exitedBeforeHandshake }

        let bootstrap = """
        import os, socket, threading
        import backend.api as api
        import uvicorn
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("127.0.0.1", 0))
        sock.listen(128)
        port = sock.getsockname()[1]
        with open(os.environ["OST_HANDSHAKE_FILE"], "w") as f:
            f.write("OSTTRACKER_READY port=%d token=%s\\n" % (port, os.environ["OST_API_TOKEN"]))
        def _run():
            uvicorn.Server(uvicorn.Config(api.app, log_level="warning", lifespan="on")).run(sockets=[sock])
        threading.Thread(target=_run, daemon=True).start()
        """
        guard pythonRun(bootstrap) == 0 else { throw SidecarError.exitedBeforeHandshake }

        // Poll the handshake file (the server may still be binding — the
        // caller's waitUntilHealthy() covers that race).
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: handshakeURL),
               let line = String(data: data, encoding: .utf8),
               line.hasPrefix("OSTTRACKER_READY") {
                return try SidecarHandshakeParser.parse(line)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        throw SidecarError.handshakeTimeout
    }

    /// python-build-standalone iOS layout, staged by packaging/08_ios_build.sh
    /// into the app bundle's Resources/python.
    private static func pythonRoot() -> URL? {
        Bundle.main.resourceURL?.appending(path: "python")
    }
}

#endif  // os(iOS)
