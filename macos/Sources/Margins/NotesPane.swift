import SwiftUI
import MarginsCore
import MarginsModel

struct NotesPane: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ReaderModel.self) private var reader
    @FocusState private var editorFocused: Bool

    var body: some View {
        @Bindable var reader = reader
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notes")
                    .font(.headline)
                Spacer()
                Text("\(reader.noteWordCount ?? 0) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if reader.isNoteDirty {
                    Button("Save", action: saveNote)
                }
            }
            if let error = reader.notesError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            TextEditor(text: $reader.noteBody)
                .focused($editorFocused)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
        }
        .padding()
        .frame(minWidth: 280, idealWidth: 340, maxHeight: .infinity, alignment: .topLeading)
        .task(id: reader.chapter?.key) {
            await model.loadChapterNote(reader: reader)
        }
        .onChange(of: reader.notesFocusRequest) {
            editorFocused = true
        }
        .onChange(of: reader.readerFocusRequest) {
            editorFocused = false
        }
    }

    private func saveNote() {
        Task { await model.saveChapterNote(reader: reader) }
    }
}
