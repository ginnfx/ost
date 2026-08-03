// The user-writable package layer: yt-dlp updates land in Application
// Support, never inside the signed bundle. api.py prepends this directory to
// sys.path (OST_WRITABLE_SITE) so it shadows the bundled fallback copy.
// macOS-only: it needs the bundled `uv` binary and a writable Application
// Support dir; iOS ships a fixed yt-dlp copy (see EmbeddedSidecar).

#if os(macOS)

import Foundation

enum WritableLayer {
    nonisolated static var sitePackagesURL: URL {
        URL.applicationSupportDirectory.appending(path: "OSTTracker/site-packages")
    }

    static var isPopulated: Bool {
        FileManager.default.fileExists(
            atPath: sitePackagesURL.appending(path: "yt_dlp").path(percentEncoded: false)
        )
    }

    /// `uv pip install yt-dlp` into a STAGING directory, then swap it in
    /// atomically. Installing straight into the live directory races the
    /// sidecar's import of those same files (this runs concurrently with the
    /// sidecar launch): an in-place upgrade removes and rewrites the package
    /// under the interpreter's feet, and a half-written yt_dlp poisons every
    /// resolve for the session. Failure is non-fatal: the bundled yt-dlp
    /// keeps working until the next attempt.
    static func update() async throws {
        guard let resources = Bundle.main.resourceURL else { return }
        let uv = resources.appending(path: "bin/uv")
        let python = resources.appending(path: "python-runtime/bin/python3.11")
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: uv.path(percentEncoded: false)) else { return }

        let staging = sitePackagesURL.deletingLastPathComponent()
            .appending(path: "site-packages.staging")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = uv
        process.arguments = [
            "pip", "install",
            "--python", python.path(percentEncoded: false),
            "--target", staging.path(percentEncoded: false),
            "yt-dlp",
        ]
        try process.run()
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
        guard process.terminationStatus == 0 else {
            try? fm.removeItem(at: staging)
            print("GATE writable_layer updated=false (uv exit \(process.terminationStatus))")
            return
        }
        if fm.fileExists(atPath: sitePackagesURL.path(percentEncoded: false)) {
            _ = try fm.replaceItemAt(sitePackagesURL, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: sitePackagesURL)
        }
        print("GATE writable_layer updated=true path=\(sitePackagesURL.path(percentEncoded: false))")
    }
}

#endif  // os(macOS)
