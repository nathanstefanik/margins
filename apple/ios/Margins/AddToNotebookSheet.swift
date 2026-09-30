import MarginsCore
import MarginsModel
import SwiftUI

/// A passage awaiting a target notebook — `PassageSource` isn't
/// Identifiable, so sheets present this wrapper. `cfi` carries the
/// selection's range for the reader's post-add highlight restore.
struct NotebookAddCandidate: Identifiable {
    let id = UUID()
    let source: PassageSource
    let preview: String
    var cfi: String?
}

/// "Add to Notebook…" — pick a notebook (or start a new one), optionally
/// write a line of commentary, and the passage lands in the file. Used
/// from search rows, the reader's selection menu, and the marks sheet.
struct AddToNotebookSheet: View {
    @Environment(NotebookModel.self) private var notebooks

    /// How the passage enters the notebook (existing mark, or a reading
    /// selection the core turns into one).
    let source: PassageSource
    /// The quote text previewed at the top.
    let preview: String
    /// Called after a successful add with the notebook's title.
    let onAdded: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var chosen: String?
    @State private var commentary = ""
    @State private var newNotebookAlert = false
    @State private var newTitle = ""
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(preview)
                        .font(.system(.callout, design: .serif))
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Section("Notebook") {
                    ForEach(notebooks.notebooks) { notebook in
                        Button {
                            chosen = notebook.id
                        } label: {
                            HStack {
                                Text(notebook.title)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if chosen == notebook.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    Button {
                        newTitle = ""
                        newNotebookAlert = true
                    } label: {
                        Label("New Notebook…", systemImage: "plus")
                    }
                }
                Section("Commentary") {
                    TextField("Why it matters…", text: $commentary, axis: .vertical)
                        .lineLimit(2...5)
                }
                if let error = notebooks.errorMessage {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add to Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(chosen == nil || adding)
                }
            }
            .alert("New Notebook", isPresented: $newNotebookAlert) {
                TextField("Title", text: $newTitle)
                Button("Create") {
                    let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return }
                    Task {
                        if let summary = await notebooks.create(title: title) {
                            chosen = summary.id
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .presentationDetents([.medium, .large])
            .task { await notebooks.refresh() }
        }
    }

    private func add() {
        guard let notebookId = chosen else { return }
        adding = true
        Task {
            if await notebooks.addPassage(
                notebookId: notebookId, source: source,
                commentary: commentary.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                let title = notebooks.notebooks.first { $0.id == notebookId }?.title ?? "notebook"
                onAdded(title)
                dismiss()
            }
            adding = false
        }
    }
}
