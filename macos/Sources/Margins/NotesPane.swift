import SwiftUI
import MarginsCore
import MarginsModel

struct NotesPane: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ReaderModel.self) private var reader
    @FocusState private var editorFocused: Bool

    /// The ~100-word target the word count gently signals.
    private static let targetWords = 100
    private static let approachWords = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let error = reader.notesError {
                errorBanner(error)
            }
            editor
        }
        .padding()
        .task(id: reader.chapter?.key) {
            await model.loadChapterNote(reader: reader)
        }
        .onChange(of: reader.noteBody) {
            reader.noteEdited()
        }
        .onChange(of: reader.notesFocusRequest) {
            editorFocused = true
        }
        .onChange(of: reader.readerFocusRequest) {
            editorFocused = false
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(ReaderModel.noteHeaderText(
                chapterIndex: reader.chapter.map { Int($0.index) } ?? 0,
                chapterTitle: reader.chapter?.title
            ))
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(reader.chapter?.title ?? "")
            Spacer(minLength: 8)
            Text("\(reader.liveNoteWordCount) words")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(
                    reader.liveNoteWordCount >= Self.approachWords ? Color.primary : Color.secondary
                )
                .animation(.easeOut(duration: 0.2), value: reader.liveNoteWordCount >= Self.approachWords)
            saveStatus
        }
    }

    /// Fixed-position save state: the text fades in and out, but the space
    /// it occupies never changes, so nothing jumps when the dirty state does.
    private var saveStatus: some View {
        Text(reader.noteStatusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(minWidth: 48, alignment: .trailing)
            .opacity(reader.noteSaveStatus == .idle ? 0 : 1)
            .animation(.easeInOut(duration: 0.25), value: reader.noteSaveStatus)
    }

    private func errorBanner(_ message: String) -> some View {
        Label {
            Text(message)
                .lineLimit(3)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption)
        .foregroundStyle(.red)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.1), in: .rect(cornerRadius: 6))
    }

    // MARK: Editor

    private var editor: some View {
        @Bindable var reader = reader
        return ZStack(alignment: .topLeading) {
            TextEditor(text: $reader.noteBody)
                .focused($editorFocused)
                .font(.body)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
                .padding(4)
            if reader.noteBody.isEmpty {
                Text("Summarize this chapter in ~\(Self.targetWords) words…")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 12)
                    .padding(.leading, 12)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
