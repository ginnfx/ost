// Idle attract mode. After ~90s without input (kiosk convention for a desktop
// app) the app drifts into an ambient cover-art screensaver; any input wakes it
// instantly, and the waking click/keypress is swallowed — it only wakes, never
// acts. Mouse movement wakes too but passes through (moving is harmless).

#if os(macOS)
import AppKit
#endif
import Observation

@Observable
final class AttractModeController {
    private(set) var isActive = false

    @ObservationIgnored private var lastActivity = CFAbsoluteTimeGetCurrent()
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    // Settings-backed (read live from UserDefaults so changes take effect on the
    // next tick without restarting the monitor).
    static let enabledKey = "attractEnabled"
    static let idleSecondsKey = "attractIdleSeconds"
    static let defaultIdleSeconds: Double = 90
    private static let checkInterval: Double = 5

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }
    private var idleThreshold: CFAbsoluteTime {
        let raw = UserDefaults.standard.object(forKey: Self.idleSecondsKey) as? Double
        return raw ?? Self.defaultIdleSeconds
    }

    func start() {
        guard monitor == nil else { return }
        #if os(macOS)
        // TODO(iOS): swap the NSEvent global monitor for a UIKit idle timer /
        // gesture recognizer to detect inactivity on a companion build.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            lastActivity = CFAbsoluteTimeGetCurrent()
            guard isActive else { return event }
            isActive = false
            // First keypress/click only wakes; scroll and moves pass through.
            let swallowed: Set<NSEvent.EventType> = [.keyDown, .leftMouseDown, .rightMouseDown]
            return swallowed.contains(event.type) ? nil : event
        }
        #endif
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.checkInterval))
                guard let self else { return }
                // Disabled mid-session: drop any active overlay and never re-arm.
                guard isEnabled else {
                    if isActive { isActive = false }
                    continue
                }
                if !isActive, CFAbsoluteTimeGetCurrent() - lastActivity > idleThreshold {
                    isActive = true
                }
            }
        }
    }

    func stop() {
        #if os(macOS)
        if let monitor { NSEvent.removeMonitor(monitor) }
        #endif
        monitor = nil
        ticker?.cancel()
        ticker = nil
        isActive = false
    }
}
