// iOS root shell: bottom TabView, floating NowPlayingBar via safeAreaInset,
// error banner, and attract overlay. This is the iOS entry point
// (OSTTrackerApp switches between them via #if os(iOS)).

#if os(iOS)
import SwiftUI
import UIKit

struct IOSRootView: View {
    let store: AppStore
    @State private var tab: AppTab = .roster
    @State private var addOstRequest: AddOstRequest?
    @State private var submitterFilter: Int?
    @State private var attract = AttractModeController()
    @State private var showVisualizer = false
    @State private var morePath: [MoreDestination] = []
    @State private var keyboardVisible = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Theme.presetKey) private var themePreset = "emerald"
    @AppStorage(Theme.customAccentKey) private var customAccent = ""
    @AppStorage(Theme.motionKey) private var motionSelection = MotionMode.subtle.rawValue

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                if case .failed(let reason) = store.phase {
                    HStack(spacing: 10) {
                        Image(systemName: "wifi.slash")
                        Text(reason)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Retry") { Task { await store.start() } }
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .foregroundStyle(Theme.textPrimary)
                    .background(Theme.rust.opacity(0.25))
                }
                TabView(selection: $tab) {
                Tab("Roster", systemImage: AppTab.roster.systemImage, value: AppTab.roster) {
                    tabPage(RosterView(store: store, submitterFilter: $submitterFilter))
                }
                Tab("People", systemImage: AppTab.people.systemImage, value: AppTab.people) {
                    tabPage(PeopleView(store: store))
                }
                Tab("Notes", systemImage: AppTab.notes.systemImage, value: AppTab.notes) {
                    tabPage(NotesView(store: store))
                }
                Tab("More", systemImage: "ellipsis.circle", value: AppTab.settings) {
                    tabPage(moreView, showMiniPlayer: morePath.isEmpty)
                }
                }
            }
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
                        .padding(.bottom, showsPlayer ? 96 : 32)
                }
                .zIndex(4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Theme.bg)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .animation(Theme.motion(.feedback, reduceMotion: reduceMotion), value: store.playback?.status)
        .animation(Theme.motion(.feedback, reduceMotion: reduceMotion), value: store.lastError)
        .animation(Theme.motion(.overlay, reduceMotion: reduceMotion), value: attract.isActive)
        .sheet(item: $addOstRequest) { request in
            AddOstView(store: store, defaultSubmitterID: request.submitterID)
        }
        .fullScreenCover(isPresented: $showVisualizer) {
            VisualizerView(store: store) { showVisualizer = false }
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
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            setKeyboardVisible(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            setKeyboardVisible(false)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in attract.resetActivity() }
        )
        .onAppear { attract.start() }
        .onDisappear { attract.stop() }
    }

    private var showsPlayer: Bool {
        guard let playback = store.playback, store.nowPlayingEntry != nil else { return false }
        return playback.status == .playing || playback.status == .paused || playback.status == .resolving
    }

    private func tabPage<Content: View>(_ content: Content, showMiniPlayer: Bool = true) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if showsPlayer && showMiniPlayer && !keyboardVisible {
                NowPlayingBar(store: store, active: !attract.isActive && !showVisualizer,
                              onExpand: { showVisualizer = true })
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                    .transaction { $0.animation = nil }
            }
        }
    }

    private func setKeyboardVisible(_ visible: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { keyboardVisible = visible }
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

    private var moreView: some View {
        NavigationStack(path: $morePath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("More")
                        .font(.ostDisplay(22, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    moreGroup("Your data", rows: [
                        (.stats, "Stats", AppTab.stats.systemImage),
                        (.batches, "Batches", AppTab.batches.systemImage),
                        (.history, "History", AppTab.history.systemImage),
                    ])
                    moreGroup("App", rows: [
                        (.settings, "Settings", AppTab.settings.systemImage),
                        (.macConnection, "Mac connection", "desktopcomputer"),
                    ])
                }
                .padding(16)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: MoreDestination.self) { destination in
                Group {
                    switch destination {
                    case .stats: StatsView(store: store)
                    case .batches: BatchesView(store: store)
                    case .history: HistoryView(store: store)
                    case .settings: SettingsView()
                    case .macConnection: MacConnectionView()
                    }
                }
                .navigationTitle(destination.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
            }
        }
    }

    private func moreGroup(_ title: String, rows: [(MoreDestination, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.ostBody(12, weight: .semibold))
                .foregroundStyle(Theme.textDim)
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    NavigationLink(value: row.0) {
                        HStack(spacing: 12) {
                            Image(systemName: row.2)
                                .font(.system(size: 17))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 25)
                            Text(row.1)
                                .font(.ostBody(15))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textDim)
                        }
                        .padding(16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < rows.count - 1 { Theme.separator.frame(height: 1) }
                }
            }
            .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private enum MoreDestination: Hashable {
    case stats, batches, history, settings, macConnection

    var title: String {
        switch self {
        case .stats: "Stats"
        case .batches: "Batches"
        case .history: "History"
        case .settings: "Settings"
        case .macConnection: "Mac connection"
        }
    }
}
#endif
