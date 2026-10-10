// People and saved track ideas.

import SwiftUI

struct PeopleView: View {
    let store: AppStore
    @State private var newName = ""
    @State private var pendingDelete: Person?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("People")
                .font(.ostDisplay(22, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            HStack {
                TextField("Add person…", text: $newName)
                    .textFieldStyle(.plain)
                    .font(.ostBody(14))
                    .padding(10)
                    .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 7))
                    .frame(width: 260)
                    .onSubmit(submit)
                Button("Add", action: submit)
                    .buttonStyle(.borderedProminent)
                    .font(.ostDisplay(12, weight: .semibold))
            }
            VStack(spacing: 0) {
                    ForEach(store.people) { person in
                        HStack(spacing: 10) {
                            Text(person.name).font(.ostBody(14)).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            let count = store.leaderboard.filter { $0.ost.submitterId == person.id }.count
                            Text("\(count) submitted")
                                .font(.ostBody(12))
                                .foregroundStyle(count == 5 ? Theme.accent : Theme.textDim)
                            Button { pendingDelete = person } label: {
                                Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Theme.rust)
                            }
                            .buttonStyle(.plain)
                            .help("Delete \(person.name)")
                        }
                        .padding(12)
                        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
                    }
            }
            .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 7))
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .confirmationDialog(
            pendingDelete.map { "Delete \($0.name)?" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { person in
            Button("Delete \(person.name)", role: .destructive) {
                Task { await store.deletePerson(id: person.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { person in
            let subs = store.leaderboard.filter { $0.ost.submitterId == person.id }.count
            Text("Their \(subs) submitted OST(s) stay but become unsubmitted, and every rating they gave is removed. This can't be undone.")
        }
    }

    private func submit() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        newName = ""
        Task { await store.addPerson(name: name) }
    }
}

struct NotesView: View {
    let store: AppStore
    @State private var title = ""
    @State private var body_ = ""
    @State private var source = ""
    @State private var artist = ""
    @State private var externalLink = ""
    @State private var catalogQuery = ""
    @State private var catalogResults: [CatalogTrack] = []
    @State private var searchMessage = ""
    @State private var isSearching = false
    @State private var isSaving = false
    @State private var editingID: Int?
    @State private var pendingDelete: Note?
    @State private var promoteNote: Note?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                searchPanel
                composer
                HStack {
                    Text("Saved notes")
                        .font(.ostDisplay(15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("\(store.notes.count)")
                        .font(.ostBody(12))
                        .foregroundStyle(Theme.textDim)
                }
                if store.notes.isEmpty { emptyState } else { notesList }
            }
            .frame(maxWidth: 1050)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $promoteNote) { note in
            AddOstView(store: store, initialTitle: note.title,
                       initialSource: note.source ?? "", initialLink: note.externalLink ?? "")
        }
        .confirmationDialog(
            "Delete this note?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDelete?.id { Task { await store.deleteNote(id: id) } }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.title ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Notes")
                .font(.ostDisplay(22, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Track ideas and listening notes for a future ranking.")
                .font(.ostBody(13))
                .foregroundStyle(Theme.textDim)
        }
    }

    private var searchPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search music catalog")
                .font(.ostDisplay(15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 10) {
                TextField("Search a track, game, anime, or artist…", text: $catalogQuery)
                    .textFieldStyle(.plain)
                    .font(.ostBody(14))
                    .onSubmit(searchCatalog)
                Button { searchCatalog() } label: {
                    if isSearching { ProgressView().controlSize(.small) }
                    else { Label("Search", systemImage: "arrow.right") }
                }
                .buttonStyle(.bordered)
                .disabled(catalogQuery.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 || isSearching)
            }
            .padding(10)
            .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 7))

            if !searchMessage.isEmpty {
                Text(searchMessage)
                    .font(.ostBody(12))
                    .foregroundStyle(Theme.textDim)
            }
            if !catalogResults.isEmpty {
                VStack(spacing: 0) {
                    ForEach(catalogResults) { track in
                        Button { select(track) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "music.note")
                                    .foregroundStyle(Theme.textDim)
                                    .frame(width: 30, height: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title)
                                        .font(.ostDisplay(12, weight: .semibold))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                    Text("\(track.artist) · \(track.collection)")
                                        .font(.ostBody(11))
                                        .foregroundStyle(Theme.textDim)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "arrow.down.left")
                                    .foregroundStyle(Theme.textDim)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if track.id != catalogResults.last?.id { Divider().opacity(0.3) }
                    }
                }
                .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 7))
            }
            Text("Catalog results come from Apple Music. You can also write an idea manually below.")
                .font(.ostMono(10))
                .foregroundStyle(Theme.textDim)
        }
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Add an idea")
                    .font(.ostDisplay(15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if !artist.isEmpty {
                    Text("Found: \(artist)")
                        .font(.ostBody(12))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                }
            }
            TextField("OST title", text: $title)
                .textFieldStyle(.plain).font(.ostBody(15, weight: .semibold))
                .padding(11).background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 7))
            TextField("Game, anime, or soundtrack source (optional)", text: $source)
                .textFieldStyle(.plain).font(.ostBody(13))
                .padding(10).background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 7))
            TextField("Why this track? Any details to remember…", text: $body_, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.plain).font(.ostBody(13))
                .padding(10).background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 7))
            HStack {
                Text("Saved ideas stay across rankings and never affect scores.")
                    .font(.ostMono(10))
                    .foregroundStyle(Theme.textDim)
                Spacer()
                Button("Save for later") { saveNote() }
                    .buttonStyle(.borderedProminent)
                    .font(.ostDisplay(12, weight: .semibold))
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Your shortlist starts here", systemImage: "music.note.list",
            description: Text("Search the catalog above or save a track idea manually.")
        )
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var notesList: some View {
        LazyVStack(spacing: 0) {
            ForEach(store.notes) { note in
                let used = AddOstRules.historyConflict(
                    title: note.title, source: note.source ?? "", history: store.history
                ) != nil
                NoteCard(
                    note: note,
                    isEditing: editingID == note.id,
                    isUsed: used,
                    canPromote: store.roundInfo?.needsStart == false && !used,
                    onBeginEdit: { editingID = note.id },
                    onCommit: { newTitle, newBody in
                        editingID = nil
                        Task { await store.updateNote(id: note.id, title: newTitle, body: newBody) }
                    },
                    onCancel: { editingID = nil },
                    onDelete: { pendingDelete = note },
                    onPromote: { promoteNote = note }
                )
                if note.id != store.notes.last?.id {
                    Theme.separator.frame(height: 1)
                }
            }
        }
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 8))
    }

    private func searchCatalog() {
        let query = catalogQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 3 else { return }
        isSearching = true
        searchMessage = ""
        catalogResults = []
        Task {
            do {
                let found = try await store.searchCatalog(query)
                guard catalogQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                    isSearching = false; return
                }
                catalogResults = found
                searchMessage = found.isEmpty ? "No catalog match. Try another title or add it manually." : "Choose a result to fill your idea."
            } catch {
                searchMessage = "Catalog search is unavailable right now. You can still save an idea manually."
            }
            isSearching = false
        }
    }

    private func select(_ track: CatalogTrack) {
        title = track.title
        source = track.collection
        artist = track.artist
        externalLink = track.storeUrl ?? ""
        catalogResults = []
        searchMessage = "Filled from catalog. Edit the source if the soundtrack album name needs changing."
    }

    private func saveNote() {
        let savedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !savedTitle.isEmpty else { return }
        isSaving = true
        Task {
            let saved = await store.addNote(
                title: savedTitle, body: body_, source: source.isEmpty ? nil : source,
                artist: artist.isEmpty ? nil : artist,
                externalLink: externalLink.isEmpty ? nil : externalLink
            )
            isSaving = false
            if saved {
                title = ""; body_ = ""; source = ""; artist = ""; externalLink = ""
                catalogQuery = ""; searchMessage = ""
            }
        }
    }
}

/// A saved idea stays available across rankings. Actions remain visible on
/// touch screens as well as desktops.
private struct NoteCard: View {
    let note: Note
    let isEditing: Bool
    let isUsed: Bool
    let canPromote: Bool
    let onBeginEdit: () -> Void
    let onCommit: (_ title: String, _ body: String) -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    let onPromote: () -> Void

    @State private var draftTitle = ""
    @State private var draftBody = ""

    var body: some View {
        Group {
            if isEditing { editor } else { display }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var display: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(note.title)
                    .font(.ostDisplay(15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Spacer()
                if isUsed {
                    Text("Already ranked")
                        .font(.ostBody(11))
                        .foregroundStyle(Theme.rust)
                }
            }
            if let source = note.source, !source.isEmpty {
                Label(source, systemImage: "square.stack")
                    .font(.ostBody(11))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
            if let artist = note.artist, !artist.isEmpty {
                Label(artist, systemImage: "person")
                    .font(.ostBody(11))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
            if !note.note.isEmpty {
                Text(note.note)
                    .font(.ostBody(12))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
                    .lineLimit(3)
            }
            if let stamp = formatted(note.createdAt) {
                Text(stamp)
                    .font(.ostMono(9))
                    .foregroundStyle(Theme.textDim)
            }
            HStack(spacing: 12) {
                Button("Add to ranking", action: onPromote)
                    .buttonStyle(.bordered)
                    .font(.ostDisplay(11, weight: .semibold))
                    .disabled(!canPromote)
                Spacer(minLength: 0)
                if let link = note.externalLink, let url = URL(string: link) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .help("Open catalog link")
                    .foregroundStyle(Theme.textDim)
                }
                iconButton("pencil", Theme.textDim) {
                    draftTitle = note.title; draftBody = note.note; onBeginEdit()
                }
                iconButton("trash", Theme.rust, action: onDelete)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $draftTitle)
                .textFieldStyle(.plain).font(.ostDisplay(13, weight: .semibold))
            TextField("Details", text: $draftBody, axis: .vertical)
                .textFieldStyle(.plain).font(.ostBody(12)).foregroundStyle(Theme.textDim)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(.plain).font(.ostMono(11))
                    .foregroundStyle(Theme.textDim)
                Button("Save") {
                    let t = draftTitle.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    onCommit(t, draftBody)
                }
                .buttonStyle(.bordered).font(.ostBody(11, weight: .semibold))
            }
        }
    }

    private func iconButton(_ symbol: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
    }

    private func formatted(_ raw: String) -> String? {
        guard let date = ISO8601DateFormatter().date(from: raw) else { return nil }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }
}
