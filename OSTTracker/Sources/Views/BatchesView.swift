// The private batch key. The host splits every OST into sequential batches
// ("days") with a fixed, shuffled order; raters only ever hear the audio, so
// this screen is the one place title + franchise map back to a batch/slot.
// The host can set the batch count, drag OSTs between/within batches, and pin
// any OST so it keeps its slot through re-randomize + slide-in.

import SwiftUI

struct BatchesView: View {
    let store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Theme.motionKey) private var motionSelection = MotionMode.subtle.rawValue

    @State private var confirmRandomize = false
    @State private var isRandomizing = false
    // Row being dragged, so the batch drop targets know what's incoming.
    @State private var draggingID: Int?

    private static let countChoices = [2, 3, 4, 5]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if store.batches.isEmpty {
                    emptyState
                } else {
                    ForEach(store.batches) { group in
                        BatchSection(group: group, draggingID: $draggingID,
                                     coverEpoch: { store.coverEpoch(for: $0) }, onDrop: { ostID, slotIndex in
                            moveOST(ostID, toBatch: group.index - 1, at: slotIndex)
                        }, onTogglePin: { slot in
                            Task { await store.setPin(ostID: slot.ost.id, pinned: !slot.pinned) }
                        })
                    }
                }
            }
            .padding(20)
            .padding(.bottom, bottomClearance)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(Theme.motion(.reorder, reduceMotion: reduceMotion), value: store.batches.flatMap { $0.slots.map(\.ost.id) })
        .confirmationDialog(
            "Re-randomize batches?",
            isPresented: $confirmRandomize,
            titleVisibility: .visible
        ) {
            Button("Randomize", role: .destructive) { randomize() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This reshuffles every unpinned OST. Pinned OSTs keep their slot.")
        }
    }

    private var bottomClearance: CGFloat {
        #if os(macOS)
        12
        #else
        96
        #endif
    }

    // MARK: - Header

    private var header: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 12) {
            headerTitle
            randomizeButton
            if !store.batches.isEmpty { countControl }
        }
        #else
        HStack(alignment: .top) {
            headerTitle
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                randomizeButton
                if !store.batches.isEmpty { countControl }
            }
        }
        #endif
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Batches")
                .font(.ostDisplay(22, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            #if os(iOS)
            Text("Drag to reorder. Hold a slot to pin it.")
                .font(.ostBody(12))
                .foregroundStyle(Theme.textDim)
            #else
            Text("Drag to reorder. Right-click to pin a slot.")
                .font(.ostBody(12))
                .foregroundStyle(Theme.textDim)
                .kerning(0.6)
            #endif
            if let stamp = formattedTimestamp {
                Text("Generated \(stamp)")
                    .font(.ostMono(10))
                    .foregroundStyle(Theme.textDim)
            }
        }
    }

    private var countControl: some View {
        HStack(spacing: 8) {
            Text("DAYS")
                .font(.ostMono(10, weight: .medium))
                .foregroundStyle(Theme.textDim)
                .kerning(1.0)
            ForEach(Self.countChoices, id: \.self) { n in
                Button {
                    guard n != store.batches.count else { return }
                    Task { await store.setBatchCount(n) }
                } label: {
                    Text("\(n)")
                        .font(.ostMono(12, weight: .bold))
                        .foregroundStyle(n == store.batches.count ? Theme.bg : Theme.textPrimary)
                        .frame(width: 28, height: 26)
                .background(n == store.batches.count ? Theme.accent : Theme.cardSurface,
                            in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var randomizeButton: some View {
        Button {
            if store.batches.isEmpty {
                randomize()
            } else {
                confirmRandomize = true
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "shuffle")
                Text(store.batches.isEmpty ? "Randomize" : "Re-randomize")
            }
            .font(.ostMono(12, weight: .medium))
            .foregroundStyle(Theme.bg)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
            .opacity(isRandomizing ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isRandomizing)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No batches yet")
                .font(.ostDisplay(16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Randomize to create listening batches. At the Limit and Shining Star start pinned in Batch 1.")
                .font(.ostBody(12))
                .foregroundStyle(Theme.textDim)
                .lineLimit(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 20)
    }

    // MARK: - Actions

    private func randomize() {
        isRandomizing = true
        Task {
            await store.randomizeBatches()
            isRandomizing = false
        }
    }

    /// Rebuild the full arrangement with `ostID` removed from wherever it is and
    /// re-inserted at (batchIndex, slotIndex), then persist it server-side.
    private func moveOST(_ ostID: Int, toBatch batchIndex: Int, at slotIndex: Int) {
        var arrangement = store.batches.map { $0.slots.map(\.ost.id) }
        guard batchIndex >= 0, batchIndex < arrangement.count else { return }

        // Locate + remove the dragged id, adjusting the target index if we pull
        // it out from an earlier slot in the same batch.
        var target = slotIndex
        for bi in arrangement.indices {
            if let idx = arrangement[bi].firstIndex(of: ostID) {
                arrangement[bi].remove(at: idx)
                if bi == batchIndex, idx < target { target -= 1 }
                break
            }
        }
        target = max(0, min(target, arrangement[batchIndex].count))
        // No-op guard: dropping onto its own current position.
        arrangement[batchIndex].insert(ostID, at: target)
        Task { await store.arrangeBatches(arrangement) }
    }

    private var formattedTimestamp: String? {
        guard let raw = store.batchesGeneratedAt,
              let date = ISO8601DateFormatter().date(from: raw) else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - One batch (day)

private struct BatchSection: View {
    let group: BatchGroup
    @Binding var draggingID: Int?
    let coverEpoch: (Int) -> Int
    let onDrop: (_ ostID: Int, _ slotIndex: Int) -> Void
    let onTogglePin: (BatchSlot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("DAY \(group.day) · BATCH \(group.index)")
                    .font(.ostMono(11, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .kerning(1.2)
                Text("\(group.slots.count) OSTs")
                    .font(.ostMono(10))
                    .foregroundStyle(Theme.textDim)
            }

            VStack(spacing: 0) {
                ForEach(Array(group.slots.enumerated()), id: \.element.id) { index, slot in
                    BatchRow(slot: slot, epoch: coverEpoch(slot.ost.id))
                        .draggable(String(slot.ost.id)) {
                            BatchRow(slot: slot, epoch: coverEpoch(slot.ost.id))  // drag preview
                                .frame(width: 320)
                                .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 7))
                        }
                        .dropDestination(for: String.self) { items, _ in
                            handleDrop(items, at: index)
                        }
                        .contextMenu {
                            Button(slot.pinned ? "Unpin" : "Pin to slot") {
                                onTogglePin(slot)
                            }
                        }
                    if index < group.slots.count - 1 {
                        Divider().overlay(Theme.textDim.opacity(0.12))
                    }
                }
                // Trailing drop zone: drop below the last row to append here.
                Color.clear
                    .frame(height: 16)
                    .contentShape(Rectangle())
                    .dropDestination(for: String.self) { items, _ in
                        handleDrop(items, at: group.slots.count)
                    }
            }
            .padding(.vertical, 4)
            .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func handleDrop(_ items: [String], at slotIndex: Int) {
        guard let first = items.first, let ostID = Int(first) else { return }
        onDrop(ostID, slotIndex)
    }
}

private struct BatchRow: View {
    let slot: BatchSlot
    let epoch: Int

    var body: some View {
        HStack(spacing: 12) {
            Text("OST \(slot.slot)")
                .font(.ostMono(11, weight: .bold))
                .foregroundStyle(Theme.textDim)
                .frame(width: 58, alignment: .leading)

            CoverImage(path: slot.ost.coverImagePath, epoch: epoch)
                .scaledToFit()
                .frame(width: 36, height: 36)
                .background(Theme.bgRaised)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(slot.ost.title)
                    .font(.ostBody(13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let source = slot.ost.source, !source.isEmpty {
                    Text(source)
                        .font(.ostMono(10))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                }
                #if os(iOS)
                Text(slot.ost.submitterName ?? "Unassigned")
                    .font(.ostMono(10))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                #endif
            }

            Spacer()

            #if os(macOS)
            Text((slot.ost.submitterName ?? "Unassigned").uppercased())
                .font(.ostMono(12, weight: .bold))
                .foregroundStyle(Theme.textDim)
                .kerning(0.8)
                .lineLimit(1)
                .layoutPriority(1)
            #endif

            Image(systemName: slot.pinned ? "pin.fill" : "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(slot.pinned ? Theme.accent : Theme.textDim)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}
