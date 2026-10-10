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
    @Environment(\.scenePhase) private var scenePhase
    // Mirror the theme selection so a Settings change re-renders the content
    // tree with fresh accent colors (Theme.accent is a plain static read, so it
    // won't update children unless their subtree is rebuilt — the .id() below).
    @AppStorage(Theme.presetKey) private var themePreset = "emerald"
    @AppStorage(Theme.customAccentKey) private var customAccent = ""
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @State private var showVisualizer = false
    @State private var attract = AttractModeController()

    var body: some View {
        GeometryReader { geo in
            // Transport bar scales up modestly on big/fullscreen windows so it
            // doesn't read as a lost sliver at the bottom of a huge screen.
            let barScale = min(1.25, max(1.0, geo.size.width / 1300))
            ZStack(alignment: .bottom) {
            Theme.bg

            VStack(spacing: 0) {
                header
                content
                    .id("theme-\(themePreset)-\(customAccent)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

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
        .background(Theme.bg)
        .tint(Theme.accent)
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
        HStack(spacing: 20) {
            Text("OST TRACKER")
                .font(.ostWordmark(18, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize()
            Picker("Section", selection: $tab) {
                ForEach(AppTab.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 560)
            Spacer(minLength: 8)
            #if os(macOS)
            Button { openSettings() } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings (⌘,)")
            #endif
            Button { addOstRequest = AddOstRequest(submitterID: submitterFilter) } label: {
                Label("Add OST", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.roundInfo?.needsStart != false)
            if case .failed(let message) = store.phase {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Theme.rust)
                    .help(message)
            }
        }
        .font(.ostBody(12))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.bgRaised)
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
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
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.rust, lineWidth: 1))
        .frame(maxWidth: 480)
    }
}
