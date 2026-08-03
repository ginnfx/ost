// The macOS host owns the Python FastAPI sidecar's lifecycle: spawn, handshake,
// teardown. The sidecar makes itself a process-group leader (api.py main()), so
// teardown is one kill(-pgid, SIGTERM) with a SIGKILL backstop. Python also
// runs a parent-death watchdog, so even a SIGKILL'd host never leaks it.
//
// iOS uses EmbeddedSidecar instead (sandbox forbids subprocesses).

#if os(macOS)

import Foundation

nonisolated struct SidecarConfiguration: Sendable {
    let pythonPath: String
    let scriptPath: String
    let extraEnvironment: [String: String]

    /// Packaged runtime embedded by packaging/04_copy_runtime.sh when
    /// present, otherwise the repo checkout (dev build).
    static func resolve() -> SidecarConfiguration {
        packaged() ?? development()
    }

    /// The bundle-embedded python-build-standalone runtime, plus the
    /// user-writable package layer that shadows bundled yt-dlp.
    static func packaged() -> SidecarConfiguration? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let python = resources.appending(path: "python-runtime/bin/python3.11")
        guard FileManager.default.isExecutableFile(atPath: python.path(percentEncoded: false)) else { return nil }
        return SidecarConfiguration(
            pythonPath: python.path(percentEncoded: false),
            scriptPath: resources.appending(path: "backend/api.py").path(percentEncoded: false),
            extraEnvironment: ["OST_WRITABLE_SITE": WritableLayer.sitePackagesURL.path(percentEncoded: false)]
        )
    }

    /// Dev builds run straight out of the repo checkout; the repo root is
    /// derived from this source file's compile-time path.
    static func development() -> SidecarConfiguration {
        let repo = URL(fileURLWithPath: #filePath)      // …/OSTTracker/Sources/Sidecar/SidecarProcess.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let env = ProcessInfo.processInfo.environment
        return SidecarConfiguration(
            pythonPath: env["OST_SIDECAR_PYTHON"] ?? repo.appending(path: ".venv/bin/python3").path(percentEncoded: false),
            scriptPath: env["OST_SIDECAR_SCRIPT"] ?? repo.appending(path: "backend/api.py").path(percentEncoded: false),
            extraEnvironment: [:]
        )
    }
}

final class SidecarProcess {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private(set) var handshake: SidecarHandshake?
    private var drainTask: Task<Void, Never>?

    private static let terminateGrace: Duration = .seconds(2)
    private static let handshakePrefix = "OSTTRACKER_READY"
    private static let handshakeTimeout: Duration = .seconds(20)

    /// Spawn the sidecar and block until it prints its handshake line.
    func launch(_ config: SidecarConfiguration = .resolve()) async throws -> SidecarHandshake {
        process.executableURL = URL(fileURLWithPath: config.pythonPath)
        process.arguments = [config.scriptPath]
        if !config.extraEnvironment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment
                .merging(config.extraEnvironment) { _, new in new }
        }
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError
        try process.run()
        print("GATE sidecar_launched pid=\(process.processIdentifier)")

        // The handshake read races a watchdog: a sidecar that spawns but never
        // prints OSTTRACKER_READY (port bind stall, wedged interpreter) must
        // fail the launch loudly instead of suspending start() forever.
        let readTask = Task { [stdoutPipe] () -> SidecarHandshake in
            for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                guard line.hasPrefix(Self.handshakePrefix) else { continue }
                return try SidecarHandshakeParser.parse(line)
            }
            throw SidecarError.exitedBeforeHandshake
        }
        let watchdog = Task {
            try? await Task.sleep(for: Self.handshakeTimeout)
            readTask.cancel()
        }
        let shake: SidecarHandshake
        do {
            shake = try await readTask.value
            watchdog.cancel()
        } catch let error as SidecarError {
            watchdog.cancel()
            throw error
        } catch {
            // Cancelled by the watchdog (or the pipe closed): a live process
            // means we timed out waiting; a dead one exited before handshaking.
            watchdog.cancel()
            throw process.isRunning ? SidecarError.handshakeTimeout : SidecarError.exitedBeforeHandshake
        }
        handshake = shake
        print("GATE handshake port=\(shake.port) token_chars=\(shake.token.count)")
        // Keep draining stdout for the sidecar's lifetime. If nothing reads
        // past the handshake, a stray Python print (uncaught traceback, a
        // yt-dlp path that bypasses the quiet logger) eventually fills the
        // 64KB pipe buffer and blocks the sidecar mid-write — the whole
        // backend would freeze with no error surfaced.
        drainTask = Task { [stdoutPipe] in
            do {
                for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                    print("SIDECAR \(line)")
                }
            } catch {
                // Pipe closed with the process — nothing left to drain.
            }
        }
        return shake
    }

    nonisolated static func parseHandshake(_ line: String) throws -> SidecarHandshake {
        try SidecarHandshakeParser.parse(line)
    }

    /// SIGTERM the whole sidecar process group, wait out the grace period,
    /// then SIGKILL whatever is left. Synchronous: called from
    /// applicationWillTerminate where there is no "later".
    func terminate() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        kill(-pid, SIGTERM)
        kill(pid, SIGTERM)  // pre-setpgid race fallback; ESRCH is fine

        let deadline = ContinuousClock.now + Self.terminateGrace
        while process.isRunning, ContinuousClock.now < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            print("GATE teardown escalated=SIGKILL pgid=\(pid)")
        } else {
            print("GATE teardown clean=SIGTERM pgid=\(pid)")
        }
    }
}

#endif  // os(macOS)
