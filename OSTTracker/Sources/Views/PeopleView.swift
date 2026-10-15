// People and saved track ideas.

import SwiftUI

private extension ToolbarItemPlacement {
    static var ostLeading: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .automatic
        #endif
    }

    static var ostTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .automatic
        #endif
    }
}

private struct CatalogArtwork: View {
    let url: String?
    var size: CGFloat = 46

    var body: some View {
        Group {
            if let url, let imageURL = URL(string: url) {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            Theme.bg
            Image(systemName: "music.note")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
    }
}

struct PeopleView: View {
    let store: AppStore
    @State private var newName = ""
    @State private var showingAdd = false
    @State private var selectedPerson: Person?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("People")
                            .font(.ostDisplay(22, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(store.people.count) in this ranking")
                            .font(.ostBody(12))
                            .foregroundStyle(Theme.textDim)
                    }
                    Spacer()
                    Button { withAnimation { showingAdd.toggle() } } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }
                if showingAdd {
                    HStack {
                        TextField("Name", text: $newName)
                            .textFieldStyle(.plain)
                            .font(.ostBody(14))
                            .padding(12)
                            .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 8))
                            .onSubmit(submit)
                        Button("Add person", action: submit)
                            .buttonStyle(.borderedProminent)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if store.people.isEmpty && store.phase == .launching {
                    LoadingSkeleton(rows: 3, style: .list)
                } else if store.people.isEmpty {
                    ContentUnavailableView("No people yet", systemImage: "person.2",
                                           description: Text("Add a person to collect their OSTs and ratings."))
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(store.people) { person in
                            Button { selectedPerson = person } label: {
                                HStack(spacing: 12) {
                                    Circle().fill(Theme.personAccent(person.id))
                                        .frame(width: 10, height: 10)
                                    Text(person.name)
                                        .font(.ostBody(15, weight: .semibold))
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    let count = store.leaderboard.filter { $0.ost.submitterId == person.id }.count
                                    Text("\(count) OSTs")
                                        .font(.ostBody(12))
                                        .foregroundStyle(Theme.textDim)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Theme.textDim)
                                }
                                .padding(16)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if person.id != store.people.last?.id { Theme.separator.frame(height: 1) }
                        }
                    }
                    .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(16)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(item: $selectedPerson) { person in
            PersonProfileView(store: store, person: person)
                #if os(iOS)
                .presentationDetents([.large])
                #endif
        }
    }

    private func submit() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        newName = ""
        showingAdd = false
        Task { await store.addPerson(name: name) }
    }
}

private struct PersonProfileView: View {
    let store: AppStore
    let person: Person
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    private var submissions: [RankEntry] {
        store.leaderboard.filter { $0.ost.submitterId == person.id }
    }
    private var givenScores: [Double] {
        store.scores.values.compactMap { $0[person.id] }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 14) {
                        Circle().fill(Theme.personAccent(person.id))
                            .frame(width: 44, height: 44)
                            .overlay(Text(String(person.name.prefix(1)).uppercased())
                                .font(.ostDisplay(19, weight: .bold)).foregroundStyle(Theme.bg))
                        Text(person.name)
                            .font(.ostDisplay(24, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    HStack(spacing: 12) {
                        profileStat("OSTs", "\(submissions.count)")
                        profileStat("Ratings", "\(givenScores.count)")
                        let average = givenScores.isEmpty ? "—" : String(format: "%.1f", givenScores.reduce(0, +) / Double(givenScores.count))
                        profileStat("Avg given", average)
                    }
                    Text("Submitted OSTs")
                        .font(.ostDisplay(16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if submissions.isEmpty {
                        Text("No OSTs submitted yet.")
                            .font(.ostBody(13))
                            .foregroundStyle(Theme.textDim)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(submissions) { entry in
                                HStack(spacing: 12) {
                                    CoverImage(path: entry.ost.coverImagePath,
                                               epoch: store.coverEpoch(for: entry.ost.id))
                                        .scaledToFill()
                                        .frame(width: 46, height: 46)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.ost.title)
                                            .font(.ostBody(14, weight: .semibold))
                                            .foregroundStyle(Theme.textPrimary)
                                        Text(entry.ost.source ?? "")
                                            .font(.ostBody(11))
                                            .foregroundStyle(Theme.textDim)
                                    }
                                    Spacer()
                                    Text(entry.average.map { String(format: "%.2f", $0) } ?? "—")
                                        .font(.ostMono(13, weight: .bold))
                                        .foregroundStyle(Theme.accent)
                                }
                                .padding(12)
                                if entry.id != submissions.last?.id { Theme.separator.frame(height: 1) }
                            }
                        }
                        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(20)
            }
            .navigationTitle("Profile")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .ostLeading) {
                    Menu {
                        Button("Delete person", systemImage: "trash", role: .destructive) {
                            confirmingDelete = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More actions for \(person.name)")
                }
                ToolbarItem(placement: .ostTrailing) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Delete \(person.name)?", isPresented: $confirmingDelete) {
                Button("Delete person", role: .destructive) {
                    Task { await store.deletePerson(id: person.id); dismiss() }
                }
            } message: {
                Text("Their OSTs stay, but their ratings are removed.")
            }
        }
    }

    private func profileStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.ostMono(17, weight: .bold)).foregroundStyle(Theme.textPrimary)
            Text(title).font(.ostBody(10)).foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 8))
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
    @State private var suggestions: [CatalogTrack] = []
    @State private var searchMessage = ""
    @State private var isSearching = false
    @State private var showSearchResults = false
    @State private var showComposer = false
    @State private var isSaving = false
    @State private var editingID: Int?
    @State private var pendingDelete: Note?
    @State private var promoteNote: Note?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                searchPanel
                Button {
                    withAnimation { showComposer.toggle() }
                } label: {
                    HStack {
                        Label("Add an idea manually", systemImage: "square.and.pencil")
                        Spacer()
                        Image(systemName: showComposer ? "chevron.up" : "chevron.down")
                    }
                    .font(.ostBody(14, weight: .semibold))
                    .padding(16)
                    .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                if showComposer { composer }
                HStack {
                    Text("Saved notes")
                        .font(.ostDisplay(15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("\(store.notes.count)")
                        .font(.ostBody(12))
                        .foregroundStyle(Theme.textDim)
                }
                if store.notes.isEmpty && store.phase == .launching {
                    LoadingSkeleton(rows: 3, style: .list)
                } else if store.notes.isEmpty { emptyState } else { notesList }
            }
            .frame(maxWidth: 1050)
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .task(id: catalogQuery) {
            let query = catalogQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard query.count >= 2 else { suggestions = []; return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let found = await store.suggestCatalog(query)
            guard !Task.isCancelled,
                  catalogQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            suggestions = Array(found.prefix(4))
        }
        .sheet(isPresented: $showSearchResults) { catalogResultsSheet }
        .sheet(item: $promoteNote) { note in
            AddOstView(store: store, initialTitle: note.title,
                       initialSource: note.source ?? "", initialLink: note.externalLink ?? "")
        }
        .alert(
            "Delete this note?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
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
            Text("Track ideas for a future ranking.")
                .font(.ostBody(13))
                .foregroundStyle(Theme.textDim)
        }
    }

    private var searchPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search music catalog")
                .font(.ostDisplay(15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Find a track, then save it as an idea.")
                .font(.ostBody(12))
                .foregroundStyle(Theme.textDim)
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
            if !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(suggestions) { track in
                        Button { select(track) } label: { catalogRow(track) }
                            .buttonStyle(.plain)
                        if track.id != suggestions.last?.id { Divider().opacity(0.3) }
                    }
                }
                .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(16)
        .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func catalogRow(_ track: CatalogTrack) -> some View {
        HStack(spacing: 10) {
            CatalogArtwork(url: track.artworkURL, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.ostBody(13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text([track.artist, track.collection].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.ostBody(11))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(track.provider)
                .font(.ostMono(9))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
        }
        .padding(12)
        .contentShape(Rectangle())
    }

    private var catalogResultsSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 8) {
                    if isSearching {
                        ProgressView("Searching catalogs…")
                            .frame(maxWidth: .infinity, minHeight: 160)
                    } else if catalogResults.isEmpty {
                        ContentUnavailableView("No matches", systemImage: "magnifyingglass",
                                               description: Text(searchMessage.isEmpty ? "Try a different title or add the idea manually." : searchMessage))
                    } else {
                        ForEach(catalogResults) { track in
                            Button {
                                select(track)
                                showSearchResults = false
                            } label: { catalogRow(track) }
                                .buttonStyle(.plain)
                                .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Search results")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .ostTrailing) {
                    Button("Done") { showSearchResults = false }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        #endif
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !artist.isEmpty {
                Text("Artist: \(artist)")
                    .font(.ostBody(12))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
            TextField("OST title", text: $title)
                .textFieldStyle(.plain).font(.ostBody(15, weight: .semibold))
                .padding(11).background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 7))
            TextField("Game, anime, or soundtrack source (optional)", text: $source)
                .textFieldStyle(.plain).font(.ostBody(13))
                .padding(10).background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 7))
            TextField("Notes about this track", text: $body_, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.plain).font(.ostBody(13))
                .padding(10).background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 7))
            #if os(iOS)
            Text("Ideas carry over to new rankings.")
                .font(.ostMono(10))
                .foregroundStyle(Theme.textDim)
            HStack {
                Spacer()
                saveButton
            }
            #else
            HStack {
                Text("Ideas carry over to new rankings.")
                    .font(.ostMono(10))
                    .foregroundStyle(Theme.textDim)
                Spacer()
                saveButton
            }
            #endif
        }
        .padding(16)
        .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var saveButton: some View {
        Button("Save for later") { saveNote() }
            .buttonStyle(.borderedProminent)
            .font(.ostDisplay(12, weight: .semibold))
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No saved notes", systemImage: "music.note.list",
            description: Text("Save a track idea to see it here.")
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
        showSearchResults = true
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
                searchMessage = found.isEmpty ? "No matches. Try another search or add the track manually." : ""
            } catch {
                searchMessage = "Catalog search failed. Try again or add the track manually."
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
        suggestions = []
        searchMessage = ""
        showComposer = true
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
