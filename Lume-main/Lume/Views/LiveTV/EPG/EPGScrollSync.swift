//
//  EPGScrollSync.swift
//  Lume
//
//  The guide's shared scroll state: the measured offset for event-time math,
//  the mirror the frozen panes render from, and the block-quantized
//  realization windows the programme rows and channel column realize their
//  content inside.
//

import SwiftUI

// MARK: - Scroll sync

/// Shared scroll state for the guide's panes.
///
/// `offset`/`viewport` are the measured scroll geometry, updated every frame
/// while scrolling but deliberately **not observed**: a per-frame observable
/// write forces a SwiftUI transaction — and with it a hosting-view layout
/// pass — on every scrolled frame, which device traces showed dominating the
/// guide's scroll time. Event-time math (realization windows, follow targets,
/// virtual navigation) reads them directly.
///
/// `mirror` is what the frozen ruler and channel column render from. On touch
/// platforms it is written per frame from the measured offset (finger-driven
/// scrolling has no known target). On tvOS every scroll is programmatic, so
/// it is written once per move inside an animation matching the scroll —
/// CoreAnimation interpolates both, and the main thread does no per-frame
/// mirroring work.
///
/// The windows are quantized to blocks so they change on block crossings —
/// not per scrolled frame. Observation tracks properties independently: the
/// panes read only `mirror`, the rows only `window`/`rowWindow`.
@MainActor
@Observable
final class EPGScrollSync {
    @ObservationIgnored var offset = CGPoint.zero
    @ObservationIgnored var viewport = CGSize.zero
    var mirror = CGPoint.zero
    var window = EPGRealizeWindow(start: 0, end: 0)
    var rowWindow = EPGRealizeWindow(start: 0, end: 0)
}

/// The range along one scroll axis worth realizing: the viewport plus one
/// block on both sides, snapped to block boundaries.
struct EPGRealizeWindow: Equatable {
    var start: CGFloat
    var end: CGFloat

    static func around(offset: CGFloat, viewport: CGFloat, blockLength: CGFloat) -> EPGRealizeWindow {
        let start = ((offset - blockLength) / blockLength).rounded(.down) * blockLength
        let end = ((offset + viewport + blockLength) / blockLength).rounded(.up) * blockLength
        return EPGRealizeWindow(start: max(0, start), end: max(0, end))
    }
}

// MARK: - Scroll requests

/// A programmatic scroll the scroller asks the grid to perform. Tokenized so
/// consecutive requests to the same point still fire.
struct EPGScrollRequest: Equatable {
    var token: Int
    var point: CGPoint
    var animated: Bool
}

// MARK: - Selection

/// A tapped programme, carried to the guide's detail sheet.
struct EPGSelection: Identifiable {
    let id: String
    let stream: LiveStream
    let cell: EPGProgramCell
}

// MARK: - Virtual focus

/// What the tvOS guide treats as focused. Neither the channel column nor the
/// grid cells are individually focusable — a single focusable surface
/// interprets the remote and this value drives the highlight — so the focus
/// engine tracks one view for the whole guide.
enum EPGVirtualFocus: Equatable {
    /// The channel column entry of a row — the guide's navigation hub.
    case channel(rowIndex: Int)
    /// A programme cell.
    case cell(rowIndex: Int, cellID: String)

    var rowIndex: Int {
        switch self {
        case let .channel(rowIndex): rowIndex
        case let .cell(rowIndex, _): rowIndex
        }
    }
}
