// iOS root shell: bottom TabView, glass backdrop, floating NowPlayingBar via
// safeAreaInset, VisualizerView as fullScreenCover, error banner, and attract
// overlay. The macOS RootView is used on macOS; this view is the iOS entry point
// (OSTTrackerApp switches between them via #if os(iOS)).

#if os(iOS)
import SwiftUI

extension AppTab {
    var systemImage: String {
        switch self {
        case .roster:  return "list.star"
        case .people:  return "person.2"
        case .notes:   return "note.text"
        case .stats:   return "chart.bar"
        case .batches: return "square.grid.2x2"
        case .history: return "clock"
        }
    }
}

struct IOSRootView: View {
    let store: AppStore
    @State private var tab: AppTab = .roster
    @State private var addOstRequest: AddOstRequest?
    @State private var submitterFilter: Int?
    @State private var showSettings = false
    @State private var showVisualizer = false
    @State private var attract = AttractModeController()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Theme.presetKey) private var themePreset = "emerald"
    @AppStorage(Theme.customAccentKey) private var customAccent = ""

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            TabView(selection: $tab) {
                Tab("Roster", systemImage: AppTab.roster.systemImage, value: AppTab.roster) {
                    RosterView(store: store, submitterFilter: $submitterFilter)
                }
                Tab("People", systemImage: AppTab.people.systemImage, value: AppTab.people) {
                    PeopleView(store: store)
                }
                Tab("Notes", systemImage: AppTab.notes.systemImage, value: AppTab.notes) {
                    NotesView(store: store)
                }
                Tab("Stats", systemImage: AppTab.stats.systemImage, value: AppTab.stats) {
                    StatsView(store: store)
                }
                Tab("Batches", systemImage: AppTab.batches.systemImage, value: AppTab.batches) {
                    BatchesView(store: store)
                }
                Tab("History", systemImage: AppTab.history.systemImage, value: AppTab.history) {
                    HistoryView(store: store)
                }
            }
            // Float the NowPlayingBar above the tab bar, inside the safe area.
            .safeAreaInset(edge: .bottom) {
                if store.playback?.status != nil, store.playback?.status != .idle {
                    NowPlayingBar(
                        store: store,
                        onExpand: { showVisualizer = true },
                        active: !showVisualizer && !attract.isActive
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // Overlay for the iOS navigation bar header (title + action buttons).
            .safeAreaInset(edge: .top) { topBar }
            .id("theme-\(themePreset)-\(customAccent)")

            if attract.isActive {
                AttractOverlay(store: store)
                    .zIndex(3)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            if let message = store.lastError {
                VStack {
                    Spacer()
                    ErrorBanner(message: message)
                        .padding(.horizontal, 16)
                        .padding(.bottom, store.playback?.status != nil && store.playback?.status != .idle ? 130 : 32)
                }
                .zIndex(4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Theme.bg)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.playback?.status)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.lastError)
        .animation(.easeInOut(duration: 1.5), value: attract.isActive)
        .sheet(item: $addOstRequest) { request in
            AddOstView(store: store, defaultSubmitterID: request.submitterID)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .fullScreenCover(isPresented: $showVisualizer) {
            VisualizerView(store: store) {
                SoundKit.shared.play(.dismiss)
                showVisualizer = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.onBecameActive() }
        }
        .onChange(of: tab) { _, _ in
            SoundKit.shared.play(.tabSwitch)
            HapticKit.selection()
        }
        .onChange(of: store.lastError) { _, error in
            if error != nil { HapticKit.notification(.error) }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in attract.resetActivity() }
        )
        .onAppear { attract.start() }
        .onDisappear { attract.stop() }
    }

    // Compact header: wordmark left, status icon + action buttons right.
    // 4 × 40pt buttons + 6pt spacing fits on a 390pt iPhone without overflow.
    // Phase error is icon-only — full message surface via the bottom ErrorBanner.
    private var topBar: some View {
        HStack(spacing: 12) {
            Text("OST TRACKER")
                .font(.ostWordmark(17, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
            if case .failed = store.phase {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Theme.rust)
                    .accessibilityLabel("Backend unavailable")
            }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Settings")
            Button { addOstRequest = AddOstRequest(submitterID: submitterFilter) } label: {
                Image(systemName: "plus")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Add OST")
            .disabled(store.roundInfo?.needsStart != false)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(Theme.bgRaised)
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
    }
}
#endif
