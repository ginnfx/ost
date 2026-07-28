// Advanced cover changer (sheet). Fetches cover candidates from the backend
// (iTunes, MusicBrainz, the OST's own YouTube link, YouTube search) and lets the
// user pick one — or paste any image URL. Every download + accent recompute
// happens server-side; this view only presents choices and posts the pick.

import SwiftUI

struct CoverPickerView: View {
    let store: AppStore
    let ostID: Int
    var accent: Color = Theme.accent
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [CoverCandidate] = []
    @State private var loading = true
    @State private var manualURL = ""
    @State private var applying = false

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            manualEntry
            candidateArea
        }
        .padding(24)
        .frame(width: 540)
        .preferredColorScheme(.dark)
        .task {
            candidates = await store.coverCandidates(ostID: ostID)
            loading = false
        }
    }

    private var header: some View {
        HStack {
            Text("CHANGE COVER")
                .font(.ostDisplay(18, weight: .bold))
                .foregroundStyle(accent)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paste an image URL").font(.ostDisplay(11)).foregroundStyle(Theme.textDim)
            HStack(spacing: 8) {
                TextField("https://…", text: $manualURL)
                    .textFieldStyle(.plain).font(.ostBody(13)).padding(8)
                    .glassEffect(.regular, in: ChamferedRect(cut: 8))
                Button("Use") { apply(manualURL) }
                    .buttonStyle(.glass)
                    .tint(accent)
                    .font(.ostDisplay(12, weight: .semibold))
                    .disabled(manualURL.trimmingCharacters(in: .whitespaces).isEmpty || applying)
            }
        }
    }

    @ViewBuilder
    private var candidateArea: some View {
        if loading {
            HStack { Spacer(); ProgressView().controlSize(.large); Spacer() }
                .frame(height: 200)
        } else if candidates.isEmpty {
            Text("No candidates found. Paste an image URL above instead.")
                .font(.ostBody(12)).foregroundStyle(Theme.textDim)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(candidates) { candidate in
                        cell(candidate)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 400)
            .overlay { if applying { ProgressView().controlSize(.large) } }
            .disabled(applying)
        }
    }

    private func cell(_ candidate: CoverCandidate) -> some View {
        Button { apply(candidate.imageUrl) } label: {
            VStack(spacing: 5) {
                AsyncImage(url: URL(string: candidate.thumbUrl)) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .empty: ZStack { Theme.bgRaised; ProgressView() }
                    default: ZStack {
                        Theme.bgRaised
                        Image(systemName: "photo").foregroundStyle(Theme.textDim)
                    }
                    }
                }
                .frame(width: 120, height: 120)
                .clipShape(ChamferedRect(cut: 8))
                .overlay(ChamferedRect(cut: 8).stroke(accent.opacity(0.35), lineWidth: 1))
                Text(candidate.sourceName)
                    .font(.ostMono(9)).foregroundStyle(Theme.textDim).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help(candidate.label)
    }

    private func apply(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !applying else { return }
        applying = true
        Task {
            await store.setCover(ostID: ostID, imageURL: trimmed)
            dismiss()
        }
    }
}
