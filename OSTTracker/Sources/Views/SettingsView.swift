// Settings embedded in the main app navigation.

import SwiftUI
#if os(macOS)
import AppKit
import SystemConfiguration
#endif

struct SettingsView: View {
    @AppStorage(Theme.presetKey) private var presetID = "emerald"
    @AppStorage(Theme.customAccentKey) private var customAccentHex = ""
    @AppStorage(Theme.fxDefaultsKey) private var fxEnabled = true
    @AppStorage(Theme.fxIntensityKey) private var fxIntensity = 1.0
    @AppStorage(Theme.visualizerKey) private var visualizerEnabled = true
    @AppStorage(Theme.motionKey) private var motionMode = MotionMode.subtle.rawValue
    @AppStorage(SoundKit.mutedDefaultsKey) private var uiSoundsMuted = false
    @AppStorage(AttractModeController.enabledKey) private var attractEnabled = true
    @AppStorage(AttractModeController.idleSecondsKey) private var attractIdle = AttractModeController.defaultIdleSeconds
    #if os(macOS)
    @AppStorage("ost.lan.enabled") private var lanEnabled = false
    #endif

    // Working color for the custom picker; seeded from whatever accent is live.
    @State private var customColor = Theme.accent
    @State private var roundStatus: RoundStatus?
    @State private var retireChallenge: RetireChallenge?
    @State private var typedWord = ""
    @State private var roundActionInFlight = false
    @State private var showingBackupExporter = false
    @State private var showingBackupImporter = false
    @State private var backupDocument = OSTBackupDocument(data: Data())
    @State private var backupMessage: String?
    @State private var backupError: String?
    @State private var pendingBackupSnapshot: Data?
    @State private var showingRestoreConfirmation = false

    private var usingCustom: Bool { !customAccentHex.isEmpty }

    var body: some View {
        Form {
            CloudAccountSection()
            #if os(macOS)
            CompetitionAccountSection()
            #endif
            backupSection
            appearance
            competition
            localNetwork
            roundManagement
            effects
            screensaver
            sound
        }
        .formStyle(.grouped)
        .tint(Theme.accent)
        .frame(maxWidth: 760, maxHeight: .infinity)
        #if os(iOS)
        .padding(.horizontal, 0)
        #else
        .padding(24)
        #endif
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { roundStatus = await AppStore.shared.roundStatus() }
        .fileExporter(isPresented: $showingBackupExporter, document: backupDocument,
                      contentType: .json, defaultFilename: "OSTTracker-Backup") { result in
            switch result {
            case .success: backupMessage = "Backup saved. Keep it somewhere outside this app, such as Files or iCloud Drive."
            case .failure(let error): backupError = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $showingBackupImporter, allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            Task {
                do {
                    let urls = try result.get()
                    guard let url = urls.first else { return }
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    let portable = try JSONDecoder().decode(PortableBackup.self, from: data)
                    pendingBackupSnapshot = try portable.validatedSnapshot()
                    showingRestoreConfirmation = true
                } catch {
                    backupError = error.localizedDescription
                }
            }
        }
        .alert("Backup", isPresented: Binding(get: { backupMessage != nil }, set: { if !$0 { backupMessage = nil } })) {
            Button("OK") { backupMessage = nil }
        } message: { Text(backupMessage ?? "") }
        .alert("Couldn’t use backup", isPresented: Binding(get: { backupError != nil }, set: { if !$0 { backupError = nil } })) {
            Button("OK") { backupError = nil }
        } message: { Text(backupError ?? "") }
        .confirmationDialog("Restore this backup?", isPresented: $showingRestoreConfirmation,
                            titleVisibility: .visible) {
            Button("Replace app data and sync", role: .destructive) {
                guard let snapshot = pendingBackupSnapshot else { return }
                Task {
                    do {
                        try await AppStore.shared.restoreBackupSnapshot(snapshot)
                        backupMessage = "Backup restored. OST Tracker is syncing the restored data to your account."
                    } catch { backupError = error.localizedDescription }
                    pendingBackupSnapshot = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingBackupSnapshot = nil }
        } message: {
            Text("This replaces the data on this device and then syncs it to Supabase and your other devices.")
        }
        #if os(macOS)
        .onChange(of: lanEnabled) { _, _ in
            Task { await AppStore.shared.reconfigureLAN() }
        }
        #endif
        .sheet(item: $retireChallenge) { challenge in
            VStack(alignment: .leading, spacing: 16) {
                Text("Retire this ranking?").font(.title2.bold())
                Text("Current OSTs move to History. You can restore their ratings and batches while the roster is empty. People and notes stay.")
                    .font(.callout)
                Text("Type \(challenge.word) to confirm")
                    .font(.headline.monospaced())
                TextField("Confirmation word", text: $typedWord)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                HStack {
                    Button("Cancel") { retireChallenge = nil; typedWord = "" }
                    Spacer()
                    Button("Retire ranking", role: .destructive) {
                        roundActionInFlight = true
                        Task {
                            let succeeded = await AppStore.shared.retireRound(challengeId: challenge.challengeId, word: typedWord)
                            roundActionInFlight = false
                            if succeeded {
                                retireChallenge = nil
                                typedWord = ""
                                roundStatus = await AppStore.shared.roundStatus()
                            }
                        }
                    }
                    .disabled(typedWord != challenge.word || roundActionInFlight)
                }
            }
            .padding(24)
            .frame(maxWidth: 410)
        }
    }

    private var backupSection: some View {
        Section("Data & recovery") {
            Text("Supabase keeps your devices in sync. A backup file saves your OSTs, ratings, notes, and history to Files. A free Xcode install may stop opening after 7 days, but it doesn’t erase saved app data. Reinstall the signed app to resume; cover art syncs back from Supabase when you’re signed in.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task {
                    do {
                        let snapshot = try await AppStore.shared.makeBackupSnapshot()
                        let portable = PortableBackup(snapshot: snapshot)
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        backupDocument = OSTBackupDocument(data: try encoder.encode(portable))
                        showingBackupExporter = true
                    } catch { backupError = error.localizedDescription }
                }
            } label: {
                Label("Save backup to Files…", systemImage: "square.and.arrow.down")
            }
            Button { showingBackupImporter = true } label: {
                Label("Restore from backup…", systemImage: "arrow.counterclockwise")
            }
            .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func settingsGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(iOS)
        DisclosureGroup(title, content: content)
        #else
        Section(title, content: content)
        #endif
    }

    // MARK: Competition

    @ViewBuilder
    private var localNetwork: some View {
        #if os(macOS)
        Section("iPhone connection") {
            Toggle("Allow iPhone access on this local network", isOn: $lanEnabled)
                .disabled(AppStore.shared.isReconfiguringLAN)
            if lanEnabled, let code = AppStore.shared.lanPairingCode {
                let host = (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? ProcessInfo.processInfo.hostName
                let localHost = host.hasSuffix(".local") ? host : "\(host).local"
                let address = "http://\(localHost):8765"
                LabeledContent("Mac address", value: address)
                LabeledContent("Pairing code", value: code)
                    .textSelection(.enabled)
                Button("Copy connection") {
                    var link = URLComponents()
                    link.scheme = "osttracker"
                    link.host = "pair"
                    link.queryItems = [
                        URLQueryItem(name: "address", value: address),
                        URLQueryItem(name: "token", value: code),
                    ]
                    if let text = link.string {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
                Text("Paste the connection on your iPhone. Keep this Mac and the app running while connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if lanEnabled {
                Text("Starting local network access…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        #else
        Section("Mac connection") {
            if let address = UserDefaults.standard.string(forKey: LANConnection.addressKey) {
                LabeledContent("Connected to", value: address)
            }
            Button("Reconnect to Mac") { Task { await AppStore.shared.start() } }
            Button("Forget this Mac") { AppStore.shared.disconnectFromMac() }
        }
        #endif
    }

    /// The one server-backed preference here: the elimination threshold lives in
    /// Python's app_settings (it changes competition results), so this reads and
    /// writes the store rather than UserDefaults.
    private var competition: some View {
        settingsGroup("Competition") {
            Stepper(value: thresholdBinding, in: 1...20) {
                LabeledContent("Eliminate at", value: "\(threshold) OSTs out")
            }
            Text("Number of fallen OSTs needed to eliminate a person in Slices.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var threshold: Int { AppStore.shared.elimination?.threshold ?? 5 }

    private var thresholdBinding: Binding<Int> {
        Binding(
            get: { threshold },
            set: { new in Task { await AppStore.shared.setEliminationThreshold(new) } }
        )
    }

    private var roundManagement: some View {
        settingsGroup("Rankings") {
            LabeledContent("Current ranking", value: "\(roundStatus?.currentName ?? "None") · \(roundStatus?.activeOstCount ?? 0) OSTs")
            Button("Retire current ranking…") {
                Task {
                    typedWord = ""
                    retireChallenge = await AppStore.shared.retireChallenge()
                }
            }
            .disabled((roundStatus?.activeOstCount ?? 0) == 0 || roundActionInFlight)
            if let roundStatus {
                ForEach(roundStatus.archives.filter { $0.restoredAt == nil }) { archive in
                    HStack {
                        Text("\(archive.name) · \(archive.ostCount) OSTs")
                            .font(.caption)
                        Spacer()
                        Button("Restore") {
                            roundActionInFlight = true
                            Task {
                                let succeeded = await AppStore.shared.restoreRound(id: archive.id)
                                roundActionInFlight = false
                                if succeeded { self.roundStatus = await AppStore.shared.roundStatus() }
                            }
                        }
                        .disabled(roundStatus.activeOstCount != 0 || roundActionInFlight)
                    }
                }
            }
            Text("Restore requires an empty current ranking.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Appearance

    private var appearance: some View {
        settingsGroup("Appearance") {
            Picker("Motion", selection: $motionMode) {
                ForEach(MotionMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            Text("macOS Reduce Motion overrides this setting.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Accent theme") {
                HStack(spacing: 10) {
                    ForEach(Theme.presets) { preset in
                        Button { selectPreset(preset.id) } label: {
                            Circle()
                                .fill(Color(hex: preset.accentHex))
                                .frame(width: 24, height: 24)
                                .overlay {
                                    if !usingCustom, presetID == preset.id {
                                        Circle().strokeBorder(.primary, lineWidth: 2)
                                    }
                                }
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .help(preset.name)
                        .accessibilityLabel("\(preset.name) accent")
                    }
                }
            }
            ColorPicker("Custom accent", selection: $customColor, supportsOpacity: false)
                .onChange(of: customColor) { _, new in applyCustom(new) }
            if usingCustom {
                Button("Reset to preset") {
                    customAccentHex = ""
                    customColor = Theme.accent
                }
                .font(.callout)
            }
        }
    }

    private func selectPreset(_ id: String) {
        customAccentHex = ""       // preset wins only when no custom is set
        presetID = id
        customColor = Color(hex: Theme.presets.first { $0.id == id }?.accentHex ?? Theme.defaultAccentHex)
    }

    private func applyCustom(_ color: Color) {
        let hex = PlatformColor(color).srgbHexString
        guard Theme.isValidHex(hex), hex != customAccentHex else { return }
        customAccentHex = hex
    }

    // MARK: Effects

    private var effects: some View {
        settingsGroup("Visual effects") {
            Toggle("Show player visualizer", isOn: $visualizerEnabled)
            Toggle("Music-reactive effects", isOn: $fxEnabled)
            Picker("Spectrum intensity", selection: $fxIntensity) {
                Text("Subtle").tag(0.5)
                Text("Default").tag(1.0)
                Text("Vivid").tag(1.5)
            }
            .pickerStyle(.segmented)
            .disabled(!visualizerEnabled)
        }
    }

    // MARK: Screensaver

    private var screensaver: some View {
        settingsGroup("Screensaver") {
            Toggle("Idle attract mode", isOn: $attractEnabled)
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Idle timeout", value: idleLabel)
                Slider(value: $attractIdle, in: 30...300, step: 15)
                    .disabled(!attractEnabled)
            }
        }
    }

    private var idleLabel: String {
        let secs = Int(attractIdle)
        return secs < 60 ? "\(secs)s" : String(format: "%.1f min", attractIdle / 60)
    }

    // MARK: Sound

    private var sound: some View {
        settingsGroup("Sound") {
            Toggle("Mute UI sounds", isOn: $uiSoundsMuted)
        }
    }
}
