import DioramaCore
import SwiftUI

/// A session's tags and notes, editable in place in the session header.
struct AnnotationsBar: View {
    @Environment(AppModel.self) private var model
    let session: SessionInfo
    @State private var newTag = ""
    @State private var editingNotes = false
    @State private var notesDraft = ""

    var tags: [String] { session.tags ?? [] }
    var notes: String { session.notes ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "tag").font(.caption).foregroundStyle(.secondary)
                ForEach(tags, id: \.self) { t in
                    TagChip(text: t) { save(SessionAnnotations(tags: tags.filter { $0 != t })) }
                }
                TextField("Add tag", text: $newTag)
                    .textFieldStyle(.plain).font(.caption).frame(width: 80)
                    .onSubmit {
                        let t = newTag.trimmingCharacters(in: .whitespaces)
                        newTag = ""
                        if !t.isEmpty { save(SessionAnnotations(tags: tags + [t])) }
                    }
                Spacer()
                Button {
                    notesDraft = notes
                    editingNotes = true
                } label: {
                    Label(notes.isEmpty ? "Add Notes" : "Edit Notes", systemImage: "note.text")
                }
                .controlSize(.small)
                .popover(isPresented: $editingNotes, arrowEdge: .bottom) { notesEditor }
            }
            if !notes.isEmpty {
                Text(notes).font(.callout).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    .help(notes)
            }
        }
    }

    var notesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes for “\(session.name)”").font(.headline)
            TextEditor(text: $notesDraft).font(.body).frame(width: 380, height: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Text("Included in reports and exports.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { editingNotes = false }
                Button("Save") {
                    save(SessionAnnotations(notes: notesDraft))
                    editingNotes = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    func save(_ a: SessionAnnotations) {
        Task {
            _ = await model.perform { try await $0.annotate(session.id, a) }
            await model.refreshSessions()
        }
    }
}

struct TagChip: View {
    let text: String
    var remove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            Text(text)
            if let remove, hovering {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain).help("Remove tag")
            }
        }
        .font(.caption)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
        .foregroundStyle(Color.accentColor)
        .onHover { hovering = $0 }
    }
}
