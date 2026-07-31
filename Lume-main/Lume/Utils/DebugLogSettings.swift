//
//  DebugLogSettings.swift
//  Lume
//
//  Persisted state for the end-user diagnostics feature. Enabling "Debug
//  Logging" doesn't change what the system records — Lume already writes to the
//  unified log via `Logger` — it starts a *session*: it stamps the moment
//  logging was turned on so an export only includes entries from the reproduction
//  the user is about to perform, and reveals the submit/share actions in Settings.
//

import Foundation

nonisolated enum DebugLogSettings {
    /// Whether the user has turned on diagnostic logging. Gates the export UI.
    static let enabledKey = "debug.logging.enabled"
    /// `Date.timeIntervalSinceReferenceDate` of the moment logging was enabled,
    /// used to scope an export to the current debugging session.
    static let enabledSinceKey = "debug.logging.enabledSince"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// The instant logging was last enabled, or nil if it has never been on.
    static var enabledSince: Date? {
        let raw = UserDefaults.standard.double(forKey: enabledSinceKey)
        return raw > 0 ? Date(timeIntervalSinceReferenceDate: raw) : nil
    }

    /// Records the session start. Called when the toggle flips on so a later
    /// export can bound the entries it collects.
    static func markEnabled(at date: Date) {
        UserDefaults.standard.set(date.timeIntervalSinceReferenceDate, forKey: enabledSinceKey)
    }
}
