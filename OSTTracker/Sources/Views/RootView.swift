// App chrome: black backdrop with faint glows, custom segment selector (no
// .pickerStyle(.tabs) on macOS — custom enum tabs with a sliding
// highlight), now-playing bar. Glass lives on chrome and panels; roster cards
// stay solid content surfaces.

import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case roster = "Roster"
    case people = "People"
    case notes = "Notes"
    case stats = "Stats"
    case batches = "Batches"
    case history = "History"

    var id: String { rawValue }
}

/// One Add-OST presentation: captures the submitter filter at the moment the
/// button was clicked, and its fresh identity resets the sheet's form state.
struct AddOstRequest: Identifiable {
    let id = UUID()
    let submitterID: Int?
}

struct RootView: View {
    let store: AppStore
    @State private var tab: AppTab = .roster
    // Item-based presentation (not isPresented): SwiftUI keeps an isPresented
    // sheet's content identity alive across presentations, so AddOstView's
    // @State(initialValue:) default submitter was only honored the FIRST time
    // the sheet ever opened. A fresh Identifiable item per open rebuilds the
    // form with the filter that's active right now.
    @State private var addOstRequest: AddOstRequest?
    // Lifted out of RosterView so the Add-OST sheet can default its submitter to
    // whoever the roster is currently filtered by.
    @State private var submitterFilter: Int?
    @Namespace private var tabHighlight
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SoundKit.mutedDefaultsKey) private var uiSoundsMuted = false
    @AppStorage(Theme.fxDefaultsKey) private var fxEnabled = true
    // Mirror the theme selection so a Settings change re-renders the content
    // tree with fresh accent colors (Theme.accent is a plain static read, so it
    // won't update children unless their subtree is rebuilt — the .id() below).
    @AppStorage(Theme.presetKey) private var themePreset = "emerald"
    @AppStorage(Theme.customAccentKey) private var customAccent = ""
    @Environment(\.openSettings) private var openSettings
    @State private var showVisualizer = false
    @State private var attract = AttractModeController()

    private var isMusicPlaying: Bool { store.playback?.status == .playing }

    /// Accent takeover: while an OST plays (or is paused mid-session), its
    /// cover accent leans the decorative layers toward that color. Text and
    /// controls keep fixed colors — dynamic tint on decoration only.
    private var playingAccent: Color? {
        guard store.playback?.status == .playing || store.playback?.status == .paused,
              let hex = store.nowPlayingEntry?.ost.coverAccentHex
        else { return nil }
        return Color(hex: hex)
    }

    var body: some View {
        GeometryReader { geo in
            // Transport bar scales up modestly on big/fullscreen windows so it
            // doesn't read as a lost sliver at the bottom of a huge screen.
            let barScale = min(1.25, max(1.0, geo.size.width / 1300))
            ZStack(alignment: .bottom) {
            BlackBackdrop(
                spectrum: store.player.spectrum,
                // Fully covered by the visualizer/attract overlays — don't
                // waste frames swelling glows nobody can see.
                isPlaying: isMusicPlaying && !showVisualizer && !attract.isActive,
                accentOverride: playingAccent
            )

            VStack(spacing: 0) {
                header
                content
                    .id("theme-\(themePreset)-\(customAccent)")
            }

            if store.playback?.status != nil, store.playback?.status != .idle {
                NowPlayingBar(
                    store: store,
                    onExpand: { showVisualizer = true },
                    active: !showVisualizer && !attract.isActive
                )
                    .scaleEffect(barScale, anchor: .bottom)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if showVisualizer {
                VisualizerView(store: store) {
                    SoundKit.shared.play(.dismiss)
                    showVisualizer = false
                }
                .zIndex(2)
                .transition(.opacity)
            }

            if attract.isActive {
                AttractOverlay(store: store)
                    .zIndex(3)
                    .transition(.opacity)
                    .allowsHitTesting(false)   // the controller's monitor handles waking
            }

            if let message = store.lastError {
                ErrorBanner(message: message)
                    // Clear the now-playing bar when it's up; hug the bottom otherwise.
                    .padding(.bottom, store.playback?.status != nil && store.playback?.status != .idle ? 120 : 24)
                    .zIndex(4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.playback?.status)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.lastError)
            .animation(.easeInOut(duration: 0.3), value: showVisualizer)
            .animation(.easeInOut(duration: 1.5), value: attract.isActive)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .sheet(item: $addOstRequest) { request in
            AddOstView(store: store, defaultSubmitterID: request.submitterID)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.onBecameActive() }
        }
        .onChange(of: tab) { _, _ in
            SoundKit.shared.play(.tabSwitch)
        }
        .onAppear { attract.start() }
        .onDisappear { attract.stop() }
    }

    private var header: some View {
        // GlassEffectContainer wraps every chrome glass element in the header so
        // they all share one sampling region. Without this outer container the
        // Add-OST button and SegmentSelector (which sit on top of the header
        // background glass) are glass-on-glass without a shared region and render
        // invisible. The SegmentSelector's own container is removed — the outer
        // one covers all three: header background, selector track, selector pill.
        GlassEffectContainer {
            HStack(spacing: 20) {
                Text("OST TRACKER")
                    .font(.ostWordmark(22, weight: .black))
                    .foregroundStyle(Theme.accent)
                    // Bounces on kick hits while an OST plays; dead still otherwise.
                    .musicPulse(
                        spectrum: store.player.spectrum,
                        isPlaying: isMusicPlaying && !showVisualizer && !attract.isActive,
                        amount: Theme.wordmarkBounce, driver: \.kick, anchor: .leading
                    )
                SegmentSelector(selection: $tab, namespace: tabHighlight)
                Spacer()
                Button {
                    fxEnabled.toggle()
                } label: {
                    // Same glyph both ways ("sparkles.slash" doesn't exist);
                    // brightness carries the state, matching the mute button.
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(fxEnabled ? Theme.textPrimary : Theme.textDim)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .help(fxEnabled ? "Disable music-reactive effects" : "Enable music-reactive effects")
                Button {
                    uiSoundsMuted.toggle()
                } label: {
                    Image(systemName: uiSoundsMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(uiSoundsMuted ? Theme.textDim : Theme.textPrimary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .help(uiSoundsMuted ? "Unmute UI sounds" : "Mute UI sounds")
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .help("Settings (⌘,)")
                Button { addOstRequest = AddOstRequest(submitterID: submitterFilter) } label: {
                    Label("Add OST", systemImage: "plus")
                        .font(.ostDisplay(12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                }
                // Explicit glassEffect form (not buttonStyle(.glass)+full-opacity tint,
                // which washed the material out to a solid pill). Tint carries the accent
                // as a CTA cue while the glass material stays visible; .interactive() for
                // press response. Don't stack .buttonStyle(.glass) — it would compete.
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Theme.accent.opacity(0.2)).interactive(), in: .capsule)
                switch store.phase {
                case .launching:
                    Label("starting…", systemImage: "bolt.horizontal")
                        .font(.ostMono(11)).foregroundStyle(Theme.textDim)
                case .running:
                    EmptyView()
                case .failed(let message):
                    Label(message, systemImage: "xmark.octagon")
                        .font(.ostMono(11)).foregroundStyle(Theme.rust)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            // Tint raised 0.08 -> 0.16 so the material reads over the dark, low-variation
            // top of the black backdrop instead of resolving to flat black.
            .glassEffect(.regular.tint(.white.opacity(0.16)), in: .rect)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .roster: RosterView(store: store, submitterFilter: $submitterFilter)
        case .people: PeopleView(store: store)
        case .notes: NotesView(store: store)
        case .stats: StatsView(store: store)
        case .batches: BatchesView(store: store)
        case .history: HistoryView(store: store)
        }
    }
}

/// Bottom toast for rejected writes. AppStore.reportError() feeds it and
/// auto-clears after ~5s; before this existed every failed rating, add,
/// delete, and cover apply died silently.
struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.rust)
            Text(message)
                .font(.ostBody(12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(Theme.rust.opacity(0.25)), in: ChamferedRect(cut: 10))
        .frame(maxWidth: 480)
    }
}

/// Enum tabs with a chamfered sliding highlight (matchedGeometryEffect).
/// No GlassEffectContainer here — SegmentSelector is always rendered inside
/// the header's GlassEffectContainer, which provides the shared sampling
/// region for the track glass and the selected-pill glass.
struct SegmentSelector: View {
    @Binding var selection: AppTab
    let namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        selection = tab
                    }
                } label: {
                    Text(tab.rawValue.uppercased())
                        .font(.ostDisplay(12, weight: .semibold))
                        // Bright label on the tinted-glass pill; dimmed when idle.
                        .foregroundStyle(selection == tab ? Theme.textPrimary : Theme.textDim)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background {
                            if selection == tab {
                                // Color.clear carrier: glass fills the pill cleanly.
                                // (A bare ChamferedRect() would draw its own solid
                                // foreground fill ON TOP of the glass.)
                                Color.clear
                                    .glassEffect(.regular.tint(Theme.accent.opacity(0.25)).interactive(), in: ChamferedRect(cut: 8))
                                    .matchedGeometryEffect(id: "tab-highlight", in: namespace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .glassEffect(.regular.tint(.white.opacity(0.16)), in: ChamferedRect(cut: 10))
    }
}

/// Pure black base — no gradient. A few FAINT blurred brand glows stay on top:
/// Liquid Glass refracts what's behind it, and on truly flat black every glass
/// surface would resolve to invisible. The glows are dim enough to read as
/// black, but give the glass chrome something luminous to sample.
/// While an OST plays, the glows swell and brighten with the live spectrum
/// (bass/mids/highs each drive different glows so the field moves organically).
/// The swell is applied AFTER .blur as scale/opacity transforms, so the blurred
/// texture itself is never re-rendered per frame. Paused = the static look.
struct BlackBackdrop: View {
    let spectrum: SpectrumEngine
    let isPlaying: Bool
    /// Accent takeover: non-nil while an OST plays. The three "brand" glows
    /// crossfade toward this color (~1s ease per artwork-tint practice); pink
    /// and blue stay put so the field keeps some variety.
    var accentOverride: Color? = nil

    @State private var pulse = AudioPulse()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Theme.fxDefaultsKey) private var fxEnabled = true

    var body: some View {
        let active = isPlaying && !reduceMotion && fxEnabled
        return TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !active)) { _ in
            let env = active ? pulse.update(bands: spectrum.snapshot()) : AudioEnvelopes()
            let lead = accentOverride ?? Theme.accent
            let third = accentOverride ?? Color(hex: "#8A54D0")
            ZStack {
                Color.black
                glow(lead, 0.20, size: 520, x: -260, y: -160, swell: env.bass)
                glow(Theme.pink, 0.14, size: 460, x: 340, y: 220, swell: env.bass * 0.8)
                glow(third, 0.16, size: 500, x: 220, y: -260, swell: env.mids)
                glow(lead, 0.12, size: 420, x: -200, y: 320, swell: env.bass * 0.6)
                glow(Color(hex: "#2AA0FF"), 0.10, size: 380, x: 60, y: 60, swell: env.highs)
            }
        }
        .animation(.easeInOut(duration: 1.0), value: accentOverride)
        .ignoresSafeArea()
    }

    private func glow(
        _ color: Color, _ opacity: Double, size: CGFloat, x: CGFloat, y: CGFloat, swell: Double
    ) -> some View {
        // RadialGradient instead of Circle().blur(130): visually the same soft
        // glow, but no gaussian pass — the old version re-composited five huge
        // blurs every frame while swelling and was a measurable lag source.
        // Rendered 1.5x brighter than the token, knocked back by .opacity, so
        // idle matches the original look and the swell has brightness headroom.
        RadialGradient(
            colors: [color.opacity(min(1, opacity * 1.5)), .clear],
            center: .center, startRadius: 0, endRadius: size * 0.75
        )
        .frame(width: size * 1.5, height: size * 1.5)
        .opacity(0.67 + swell * 0.33)
        .scaleEffect(1 + CGFloat(swell) * Theme.backdropSwell * Theme.fxScale)
        .offset(x: x, y: y)
    }
}
