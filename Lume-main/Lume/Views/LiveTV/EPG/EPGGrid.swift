//
//  EPGGrid.swift
//  Lume
//
//  The guide's single 2D-scrollable programme surface: it owns the scroll
//  position, executes the scroller's programmatic scroll requests, and
//  publishes the measured geometry back to the shared sync. Split from
//  `EPGGridScroller` to keep each file within the lint length budget.
//

import SwiftUI

/// The single scrollable surface. Owns its scroll position, executes the
/// scroller's scroll requests and publishes the measured geometry to the
/// shared sync. Its programme rows live in a separate child so parent updates
/// never rebuild them wholesale.
///
/// `Equatable` (wrapped in `.equatable()` by the scroller): the scroller's
/// body re-runs on virtual-focus changes, and without the gate each press
/// would re-evaluate this whole subtree. The comparison covers everything the
/// subtree renders or reacts to.
struct EPGGrid: View, Equatable {
    let rows: [EPGChannelRow]
    let timeline: EPGTimeline
    let metrics: EPGMetrics
    let now: Date
    let sync: EPGScrollSync
    let dataVersion: Int
    let nowTarget: CGFloat
    let scrollRequest: EPGScrollRequest?
    let virtualFocus: EPGVirtualFocus?
    let onPlay: (EPGChannelRow, EPGProgramCell) -> Void
    let onShowDetails: (EPGChannelRow, EPGProgramCell) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.dataVersion == rhs.dataVersion
            && lhs.rows.count == rhs.rows.count
            && lhs.nowTarget == rhs.nowTarget
            && lhs.scrollRequest == rhs.scrollRequest
            && lhs.virtualFocus == rhs.virtualFocus
            && lhs.timeline == rhs.timeline
    }

    @State private var position = ScrollPosition()
    @State private var didInitialScroll = false
    /// A combined horizontal+vertical ScrollView centers content that is shorter
    /// than the viewport. The frozen channel column pins its cells to the top, so
    /// without this the two panes drift apart when a category has only a few
    /// channels. Pinning the rows to at least the viewport height (top-aligned)
    /// keeps them level on every platform.
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            EPGRows(
                rows: rows,
                timeline: timeline,
                metrics: metrics,
                now: now,
                sync: sync,
                dataVersion: dataVersion,
                virtualFocus: virtualFocus,
                onPlay: onPlay,
                onShowDetails: onShowDetails
            )
            .equatable()
            .frame(minHeight: viewportHeight, alignment: .topLeading)
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { viewportHeight = geo.size.height }
                    .onChange(of: geo.size.height) { viewportHeight = $1 }
            }
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGRect.self) { CGRect(origin: $0.contentOffset, size: $0.containerSize) } action: { _, new in
            let clamped = CGPoint(x: max(0, new.origin.x), y: max(0, new.origin.y))
            sync.offset = clamped
            sync.viewport = new.size
            #if !os(tvOS)
                // Touch scrolling has no known target — the panes mirror the
                // measured offset per frame. tvOS mirrors per programmatic
                // move instead (see EPGGridScroller.requestScroll).
                sync.mirror = clamped
            #endif
            let window = EPGRealizeWindow.around(
                offset: clamped.x,
                viewport: new.width,
                blockLength: 30 * metrics.pointsPerMinute
            )
            if sync.window != window {
                sync.window = window
            }
            let rowWindow = EPGRealizeWindow.around(
                offset: clamped.y,
                viewport: new.height,
                blockLength: 2 * (metrics.rowHeight + metrics.rowSpacing)
            )
            if sync.rowWindow != rowWindow {
                sync.rowWindow = rowWindow
            }
        }
        .onAppear {
            guard !didInitialScroll else { return }
            didInitialScroll = true
            // Seed the realization windows and the pane mirror around the
            // initial scroll target so the first build already realizes the
            // right cells; the estimated viewports are corrected by the first
            // geometry event.
            sync.window = EPGRealizeWindow.around(
                offset: nowTarget,
                viewport: 2400,
                blockLength: 30 * metrics.pointsPerMinute
            )
            sync.rowWindow = EPGRealizeWindow.around(
                offset: 0,
                viewport: 1400,
                blockLength: 2 * (metrics.rowHeight + metrics.rowSpacing)
            )
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                sync.mirror = CGPoint(x: nowTarget, y: 0)
            }
            position.scrollTo(point: CGPoint(x: nowTarget, y: 0))
        }
        .onChange(of: scrollRequest) { _, request in
            guard let request else { return }
            if request.animated {
                withAnimation(.easeOut(duration: 0.25)) {
                    position.scrollTo(point: request.point)
                }
            } else {
                position.scrollTo(point: request.point)
            }
        }
    }
}
