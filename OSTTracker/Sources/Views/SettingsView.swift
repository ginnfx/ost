// The ⌘, Settings window. Native Form chrome (this is app chrome, not the
// themed content surface). Writes preferences straight to UserDefaults via
// @AppStorage; RootView mirrors the theme keys and re-keys its content so accent
// changes render live. FX intensity and the screensaver read their keys live.

import SwiftUI

struct SettingsView: View {
    @AppStorage(Theme.presetKey) private var presetID = "emerald"
    @AppStorage(Theme.customAccentKey) private var customAccentHex = ""
    @AppStorage(Theme.fxDefaultsKey) private var fxEnabled = true
    @AppStorage(Theme.fxIntensityKey) private var fxIntensity = 1.0
    @AppStorage(Theme.motionKey) private var motionMode = MotionMode.subtle.rawValue
    @AppStorage(SoundKit.mutedDefaultsKey) private var uiSoundsMuted = false
    @AppStorage(AttractModeController.enabledKey) private var attractEnabled = true
    @AppStorage(AttractModeController.idleSecondsKey) private var attractIdle = AttractModeController.defaultIdleSeconds

    // Working color for the custom picker; seeded from whatever accent is live.
    @State private var customColor = Theme.accent
    @State private var roundStatus: RoundStatus?
    @State private var retireChallenge: RetireChallenge?
    @State private var typedWord = ""
    @State private var roundActionInFlight = false

    private var usingCustom: Bool { !customAccentHex.isEmpty }

    var body: some View {
        Form {
            appearance
            competition
            roundManagement
            effects
            screensaver
            sound
        }
        .formStyle(.grouped)
        .tint(Theme.accent)
        .task { roundStatus = await AppStore.shared.roundStatus() }
        .sheet(item: $retireChallenge) { challenge in
            VStack(alignment: .leading, spacing: 16) {
                Text("Retire this rating?").font(.title2.bold())
                Text("All current OSTs will move to History. Ratings and the batch arrangement are saved so this round can be restored while the next one is empty. People and notes stay in place.")
                    .font(.callout)
                Text("Type \(challenge.word) to confirm")
                    .font(.headline.monospaced())
                TextField("Confirmation word", text: $typedWord)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                HStack {
                    Button("Cancel") { retireChallenge = nil; typedWord = "" }
                    Spacer()
                    Button("Retire & begin new rating", role: .destructive) {
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
        #if os(macOS)
        .frame(width: 480, height: 600)
        #endif
    }

    // MARK: Competition

    /// The one server-backed preference here: the elimination threshold lives in
    /// Python's app_settings (it changes competition results), so this reads and
    /// writes the store rather than UserDefaults.
    private var competition: some View {
        Section("Competition") {
            Stepper(value: thresholdBinding, in: 1...20) {
                LabeledContent("Eliminate at", value: "\(threshold) OSTs out")
            }
            Text("How many of a person's OSTs have to fall before they're knocked out in the roster's slice view.")
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
        Section("Rating rounds") {
            LabeledContent("Current rating", value: "\(roundStatus?.currentName ?? "None") · \(roundStatus?.activeOstCount ?? 0) OSTs")
            Button("Retire current rating…") {
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
            Text("Restore is available while the current rating is empty. Retire a new rating first to switch back to an older one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Appearance

    private var appearance: some View {
        Section("Appearance") {
            Picker("Motion", selection: $motionMode) {
                ForEach(MotionMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            Text("Minimal keeps screens still. Subtle uses quick transitions. Cinematic gives artwork and navigation more movement. macOS Reduce Motion takes priority.")
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
        Section("Effects") {
            Toggle("Music-reactive effects", isOn: $fxEnabled)
            Picker("Spectrum intensity", selection: $fxIntensity) {
                Text("Subtle").tag(0.5)
                Text("Default").tag(1.0)
                Text("Vivid").tag(1.5)
            }
            .pickerStyle(.segmented)
            .disabled(!fxEnabled)
        }
    }

    // MARK: Screensaver

    private var screensaver: some View {
        Section("Screensaver") {
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
        Section("Sound") {
            Toggle("Mute UI sounds", isOn: $uiSoundsMuted)
        }
    }
}
