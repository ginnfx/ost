// The private batch key. The host splits every OST into sequential batches
// ("days") with a fixed, shuffled order; raters only ever hear the audio, so
// this screen is the one place title + franchise map back to a batch/slot.
// The host can set the batch count, drag OSTs between/within batches, and pin
// any OST so it keeps its slot through re-randomize + slide-in.

import SwiftUI

struct BatchesView: View {
    let store: AppStore

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
                        BatchSection(group: group, draggingID: $draggingID, onDrop: { ostID, slotIndex in
                            moveOST(ostID, toBatch: group.index - 1, at: slotIndex)
                        }, onTogglePin: { slot in
                            Task { await store.setPin(ostID: slot.ost.id, pinned: !slot.pinned) }
                        })
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.96).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }
                    .animation(Theme.resortAnimation, value: store.batches)
                }
            }
            .padding(20)
            .padding(.bottom, 96)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("BATCHES")
                    .font(.ostDisplay(15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Private key — raters hear audio only · drag to arrange, right-click to pin")
                    .font(.ostMono(10))
                    .foregroundStyle(Theme.textDim)
                    .kerning(0.6)
                if let stamp = formattedTimestamp {
                    Text("Generated \(stamp)")
                        .font(.ostMono(10))
                        .foregroundStyle(Theme.textDim)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                randomizeButton
                if !store.batches.isEmpty { countControl }
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
                        .background(
                            ChamferedRect(cut: 7).fill(
                                n == store.batches.count ? Theme.accent : Theme.cardSurface
                            )
                        )
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
            .background(ChamferedRect().fill(Theme.accent))
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
            Text("Hit Randomize to split every OST into batches. At the Limit and Shining Star are pinned to Batch 1 by default — pin any other OST to lock its slot too.")
                .font(.ostBody(12))
                .foregroundStyle(Theme.textDim)
                .lineLimit(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(ChamferedRect().fill(Theme.cardSurface))
        .overlay(ChamferedRect().stroke(Theme.accent.opacity(0.25), lineWidth: 1.5))
        .padding(.top, 40)
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
    let onDrop: (_ ostID: Int, _ slotIndex: Int) -> Void
    let onTogglePin: (BatchSlot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("DAY \(group.day) · BATCH \(group.index)")
                    .font(.ostMono(11, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .kerning(1.2)
                Text("\(group.slots.count) OSTs")
                    .font(.ostMono(10))
                    .foregroundStyle(Theme.textDim)
            }

            VStack(spacing: 0) {
                ForEach(Array(group.slots.enumerated()), id: \.element.id) { index, slot in
                    BatchRow(slot: slot)
                        .draggable(String(slot.ost.id)) {
                            BatchRow(slot: slot)  // drag preview
                                .frame(width: 320)
                                .background(ChamferedRect().fill(Theme.cardSurface))
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
            .background(ChamferedRect().fill(Theme.cardSurface))
            .overlay(ChamferedRect().stroke(Theme.accent.opacity(0.18), lineWidth: 1.5))
        }
    }

    private func handleDrop(_ items: [String], at slotIndex: Int) -> Bool {
        guard let first = items.first, let ostID = Int(first) else { return false }
        onDrop(ostID, slotIndex)
        return true
    }
}

private struct BatchRow: View {
    let slot: BatchSlot

    var body: some View {
        HStack(spacing: 12) {
            Text("OST \(slot.slot)")
                .font(.ostMono(11, weight: .bold))
                .foregroundStyle(slot.pinned ? Theme.pink : Theme.accent)
                .frame(width: 58, alignment: .leading)

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
            }

            Spacer()

            Text((slot.ost.submitterName ?? "—").uppercased())
                .font(.ostMono(12, weight: .bold))
                .foregroundStyle(Theme.accent)
                .kerning(0.8)
                .lineLimit(1)
                .layoutPriority(1)

            Image(systemName: slot.pinned ? "pin.fill" : "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(slot.pinned ? Theme.pink : Theme.textDim.opacity(0.6))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}
