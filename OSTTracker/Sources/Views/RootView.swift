import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case roster = "Roster"
    case people = "People"
    case notes = "Notes"
    case stats = "Stats"
    case batches = "Batches"
    case history = "History"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .roster: "square.grid.2x2"
        case .people: "person.2"
        case .notes: "note.text"
        case .stats: "chart.bar"
        case .batches: "square.stack"
        case .history: "clock.arrow.circlepath"
        }
    }
}

/// Each presentation gets a fresh form, with the current Roster filter as its default.
struct AddOstRequest: Identifiable {
    let id = UUID()
    let submitterID: Int?
}

#if os(macOS)
struct RootView: View {
    let store: AppStore
    @State private var tab: AppTab = .roster
    @State private var addOstRequest: AddOstRequest?
    @State private var submitterFilter: Int?
    @State private var showVisualizer = false
    @State private var attract = AttractModeController()
    @State private var hoveredTab: AppTab?
    @State private var sidebarWidth: CGFloat = 200
    @State private var sidebarDragStart: CGFloat?
    @Namespace private var navigationSelection

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Theme.presetKey) private var themePreset = "emerald"
    @AppStorage(Theme.customAccentKey) private var customAccent = ""
    @AppStorage(Theme.motionKey) private var motionSelection = MotionMode.subtle.rawValue

    private var motionMode: MotionMode { MotionMode(rawValue: motionSelection) ?? .subtle }

    private var sectionTransition: AnyTransition {
        if reduceMotion || motionMode == .minimal { return .identity }
        if motionMode == .cinematic { return .opacity.combined(with: .offset(x: 12)) }
        return .opacity
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: sidebarWidth)
                    sidebarDivider
                    VStack(spacing: 0) {
                        topBar
                        ZStack {
                            content
                                .id("\(tab.rawValue)-\(themePreset)-\(customAccent)")
                                .transition(sectionTransition)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bg)
                }
                NowPlayingBar(
                    store: store,
                    onExpand: { openVisualizer() },
                    active: !showVisualizer && !attract.isActive,
                    desktop: true
                )
            }

            if showVisualizer {
                VisualizerView(store: store) {
                    SoundKit.shared.play(.dismiss)
                    withAnimation(Theme.motion(.overlay, reduceMotion: reduceMotion)) {
                        showVisualizer = false
                    }
                }
                .zIndex(2)
                .transition(.opacity)
            }

            if attract.isActive {
                AttractOverlay(store: store)
                    .zIndex(3)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            if let message = store.lastError {
                ErrorBanner(message: message)
                    .padding(.bottom, 104)
                    .zIndex(4)
                    .transition(.opacity)
            }
        }
        .background(Theme.bg)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .animation(Theme.motion(.feedback, reduceMotion: reduceMotion), value: store.lastError)
        .animation(Theme.motion(.overlay, reduceMotion: reduceMotion), value: attract.isActive)
        .sheet(item: $addOstRequest) { request in
            AddOstView(store: store, defaultSubmitterID: request.submitterID)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.onBecameActive() }
        }
        .onAppear { attract.start() }
        .onDisappear { attract.stop() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("OST TRACKER")
                .font(.ostWordmark(18, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.top, 42)
                .padding(.bottom, 30)

            Text("LIBRARY")
                .font(.ostMono(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(Theme.textDim)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            ForEach(Array(AppTab.allCases.enumerated()), id: \.element.id) { index, section in
                Button { select(section) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: section.systemImage)
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 20)
                        Text(section.rawValue)
                            .font(.ostBody(14, weight: tab == section ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(tab == section ? Theme.textPrimary : Theme.textDim)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .contentShape(Rectangle())
                    .background {
                        if tab == section {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Theme.cardSurface)
                                .matchedGeometryEffect(id: "selected-section", in: navigationSelection)
                        } else if hoveredTab == section {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Theme.cardSurface.opacity(0.55))
                        }
                    }
                    .overlay(alignment: .leading) {
                        if tab == section {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Theme.accent)
                                .frame(width: 3, height: 22)
                        }
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .onHover { hovering in hoveredTab = hovering ? section : nil }
                .help("\(section.rawValue) (⌘\(index + 1))")
                .accessibilityAddTraits(tab == section ? .isSelected : [])
            }

            Spacer(minLength: 24)

            Button { openSettings() } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.ostBody(14))
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bgRaised)
    }

    private var sidebarDivider: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                if sidebarDragStart == nil { sidebarDragStart = sidebarWidth }
                                sidebarWidth = min(270, max(168, (sidebarDragStart ?? sidebarWidth) + value.translation.width))
                            }
                            .onEnded { _ in sidebarDragStart = nil }
                    )
                    .help("Drag to resize sidebar")
            }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.roundInfo?.currentName ?? "No active ranking")
                    .font(.ostBody(14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(store.roundInfo?.needsStart == true
                     ? "Start a ranking in Roster"
                     : "\(store.leaderboard.count) OSTs in this ranking")
                    .font(.ostBody(11))
                    .foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 8)
            if case .failed(let message) = store.phase {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Theme.rust)
                    .help(message)
                    .accessibilityLabel("Backend unavailable: \(message)")
            }
            Button {
                addOstRequest = AddOstRequest(submitterID: submitterFilter)
            } label: {
                Label("Add OST", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(store.roundInfo?.needsStart != false)
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, 24)
        .frame(height: 64)
        .background(Theme.bg)
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
    }

    private func select(_ section: AppTab) {
        guard tab != section else { return }
        SoundKit.shared.play(.tabSwitch)
        withAnimation(Theme.motion(.navigation, reduceMotion: reduceMotion)) {
            tab = section
        }
    }

    private func openVisualizer() {
        guard store.playback?.status != nil, store.playback?.status != .idle else { return }
        SoundKit.shared.play(.select)
        withAnimation(Theme.motion(.overlay, reduceMotion: reduceMotion)) {
            showVisualizer = true
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
#endif

/// A rejected write stays visible long enough to read, above the player.
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
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.separator, lineWidth: 1))
        .frame(maxWidth: 480)
    }
}
