import SwiftUI
import MarginsCore
import MarginsModel

struct NotesPane: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ReaderModel.self) private var reader
    @FocusState private var editorFocused: Bool
    @State private var markDraft: MarkDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let error = reader.notesError {
                errorBanner(error)
            }
            editor
            if !reader.noteMarks.isEmpty {
                marksStrip
            }
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
        .sheet(item: $markDraft) { draft in
            markEditSheet(draft)
        }
    }

    // MARK: Marks strip

    /// The chapter note's quick marks under the editor: read, edit, delete.
    /// No capture here — creating marks is reader work (iOS first, see
    /// docs/ios-plan.md Phase 6). The editor body is untouched by strip
    /// actions: prose and marks are disjoint in the note file.
    private var marksStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text(MarkDisplay.countText(reader.noteMarks.count))
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(MarkDisplay.sortedForDisplay(reader.noteMarks), id: \.id) { mark in
                        markRow(mark)
                    }
                }
            }
            .frame(maxHeight: 160)
        }
    }

    private func markRow(_ mark: Mark) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if !mark.quote.isEmpty {
                    Text(mark.quote)
                        .font(.callout)
                        .italic()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if !mark.body.isEmpty {
                    Text(mark.body)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                let attribution = MarkDisplay.attribution(percent: mark.percent, at: mark.at)
                if !attribution.isEmpty {
                    Text(attribution)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Button {
                    markDraft = MarkDraft(mark: mark)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit this mark")
                Button {
                    Task { await model.deleteMark(mark, reader: reader) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this mark")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func markEditSheet(_ draft: MarkDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !draft.mark.quote.isEmpty {
                Text(draft.mark.quote)
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.secondary)
            }
            TextField(
                "Mark",
                text: Binding(
                    get: { markDraft?.body ?? "" },
                    set: { markDraft?.body = $0 }
                )
            )
            .onSubmit { saveMarkDraft(draft) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    markDraft = nil
                }
                Button("Save") {
                    saveMarkDraft(draft)
                }
            }
        }
        .padding()
        .frame(minWidth: 320)
    }

    private func saveMarkDraft(_ draft: MarkDraft) {
        Task {
            await model.updateMark(draft.mark, body: draft.body, reader: reader)
            markDraft = nil
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
                .foregroundStyle(.secondary)
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
                Text("What stood out? Questions, reactions, and ideas worth returning to…")
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
