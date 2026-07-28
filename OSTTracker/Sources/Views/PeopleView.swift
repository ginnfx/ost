// People + Notes tabs. Deliberately plain lists — the roster is the show.

import SwiftUI

struct PeopleView: View {
    let store: AppStore
    @State private var newName = ""
    @State private var pendingDelete: Person?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Add person…", text: $newName)
                    .textFieldStyle(.plain)
                    .font(.ostBody(14))
                    .padding(8)
                    .glassEffect(.regular, in: ChamferedRect(cut: 8))
                    .frame(width: 260)
                    .onSubmit(submit)
                Button("Add", action: submit)
                    .buttonStyle(.glass)
                    .tint(Theme.accent)
                    .font(.ostDisplay(12, weight: .semibold))
            }
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 10) {
                    ForEach(store.people) { person in
                        HStack(spacing: 10) {
                            Text(person.name).font(.ostBody(14)).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            let count = store.leaderboard.filter { $0.ost.submitterId == person.id }.count
                            Text("\(count)/5 submitted")
                                .font(.ostMono(11))
                                .foregroundStyle(count == 5 ? Theme.accent : Theme.textDim)
                            Button { pendingDelete = person } label: {
                                Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Theme.rust)
                            }
                            .buttonStyle(.plain)
                            .help("Delete \(person.name)")
                        }
                        .padding(12)
                        .glassEffect(.regular, in: ChamferedRect(cut: 8))
                    }
                }
            }
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
    @State private var editingID: Int?
    @State private var pendingDelete: Note?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            composer
            if store.notes.isEmpty {
                emptyState
            } else {
                notesList
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: 680, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
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

    private var composer: some View {
        HStack {
            TextField("Note title…", text: $title)
                .textFieldStyle(.plain).font(.ostBody(14))
                .padding(8).glassEffect(.regular, in: ChamferedRect(cut: 8))
            TextField("Details…", text: $body_)
                .textFieldStyle(.plain).font(.ostBody(14))
                .padding(8).glassEffect(.regular, in: ChamferedRect(cut: 8))
            Button("Add") {
                let t = title.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { return }
                let b = body_
                title = ""; body_ = ""
                Task { await store.addNote(title: t, body: b) }
            }
            .buttonStyle(.glass)
            .tint(Theme.accent)
            .font(.ostDisplay(12, weight: .semibold))
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No notes yet", systemImage: "note.text",
            description: Text("Jot down anything the room should remember — house rules, running jokes, verdicts.")
        )
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var notesList: some View {
        ScrollView {
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 10) {
                    ForEach(store.notes) { note in
                        NoteCard(
                            note: note,
                            isEditing: editingID == note.id,
                            onBeginEdit: { editingID = note.id },
                            onCommit: { newTitle, newBody in
                                editingID = nil
                                Task { await store.updateNote(id: note.id, title: newTitle, body: newBody) }
                            },
                            onCancel: { editingID = nil },
                            onDelete: { pendingDelete = note }
                        )
                    }
                }
            }
        }
    }
}

/// One note: static display with hover-revealed edit/delete, flipping to an
/// inline editor. Timestamps in a discreet mono caption.
private struct NoteCard: View {
    let note: Note
    let isEditing: Bool
    let onBeginEdit: () -> Void
    let onCommit: (_ title: String, _ body: String) -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @State private var draftTitle = ""
    @State private var draftBody = ""
    @State private var hovering = false

    var body: some View {
        Group {
            if isEditing { editor } else { display }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassEffect(.regular, in: ChamferedRect(cut: 8))
        .onHover { hovering = $0 }
    }

    private var display: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title).font(.ostDisplay(13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if !note.note.isEmpty {
                    Text(note.note).font(.ostBody(12)).foregroundStyle(Theme.textDim)
                }
                if let stamp = formatted(note.createdAt) {
                    Text(stamp).font(.ostMono(9)).foregroundStyle(Theme.textDim.opacity(0.7))
                }
            }
            Spacer()
            if hovering {
                HStack(spacing: 6) {
                    iconButton("pencil", Theme.accent) {
                        draftTitle = note.title; draftBody = note.note; onBeginEdit()
                    }
                    iconButton("trash", Theme.rust, action: onDelete)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: hovering)
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
                .buttonStyle(.glass).tint(Theme.accent).font(.ostMono(11, weight: .semibold))
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
