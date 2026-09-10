import SwiftUI
import MarginsCore
import MarginsModel

/// Quick capture: from reading to typing in one deliberate gesture, and
/// back without thinking about saving. Small sheet, keyboard up, focused
/// on appear, draft autosaved so nothing is ever lost; return, Done, and
/// swipe-down all commit.
struct CaptureSheet: View {
    @Environment(LibraryModel.self) private var library
    @Environment(ReaderModel.self) private var reader

    /// The active text selection, or nil for a page-anchored mark.
    let selection: ReaderBridge.ReaderSelection?
    let bridge: ReaderBridge?
    let onCommitted: (Mark) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var committed = false
    @FocusState private var focused: Bool

    private var draftKey: String {
        // Discriminated by capture type: an abandoned page-note draft must
        // not pre-fill a selection capture (different quote, same chapter).
        let kind = selection == nil ? "page" : "sel"
        return "capture.draft.\(reader.book?.id ?? "").\(reader.chapter?.key ?? "").\(kind)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let selection, !selection.text.isEmpty {
                Text(selection.text)
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } else {
                Text("Note at this page")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            TextField("Quick thought…", text: $text, axis: .vertical)
                .focused($focused)
                .onSubmit { commit() }
                .lineLimit(1...3)
                .accessibilityLabel("Quick note text")
            HStack {
                Text("Return or swipe down to save")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Button("Save", action: commit)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && (selection?.text.isEmpty ?? true))
            }
        }
        .padding()
        .presentationDetents([.height(200), .medium])
        .task {
            // Draft autosave: a mistaken dismissal or a backgrounded app
            // must never discard typing.
            text = UserDefaults.standard.string(forKey: draftKey) ?? ""
            focused = true
        }
        .onChange(of: text) {
            UserDefaults.standard.set(text, forKey: draftKey)
        }
        .onDisappear {
            if !committed {
                commit()
            }
        }
    }

    private func commit() {
        guard !committed else { return }
        committed = true
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let quote = selection?.text ?? ""
        UserDefaults.standard.removeObject(forKey: draftKey)
        guard !body.isEmpty || !quote.isEmpty, let book = reader.book, let chapter = reader.chapter else {
            dismiss()
            return
        }
        Task {
            let cfi: String?
            if let selectionCfi = selection?.cfiRange {
                cfi = selectionCfi
            } else {
                cfi = bridge?.currentPageCfi()
            }
            if let mark = await library.appendMark(
                bookId: book.id,
                chapterKey: chapter.key,
                cfi: cfi,
                percent: reader.bookPercent,
                quote: quote,
                body: body,
                reader: reader
            ) {
                // Highlight without a note: quote + empty body renders as an
                // overlay in the page.
                if !quote.isEmpty && body.isEmpty, let cfi = mark.cfi {
                    bridge?.restoreHighlights([cfi])
                }
                onCommitted(mark)
            }
            bridge?.clearSelection()
            dismiss()
        }
    }
}

/// The chapter's marks on demand: the chrome shows the count, this sheet
/// lists them; tap a mark to land on it, or edit/delete.
struct MarksSheet: View {
    @Environment(LibraryModel.self) private var library
    @Environment(ReaderModel.self) private var reader

    let onEditChapterNote: () -> Void
    var onOpen: (Mark) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var markDraft: MarkDraft?

    var body: some View {
        NavigationStack {
            Group {
                if reader.noteMarks.isEmpty {
                    ContentUnavailableView(
                        "No marks here yet",
                        systemImage: "highlighter",
                        description: Text("Select text or tap the note affordance while reading.")
                    )
                } else {
                    List {
                        ForEach(MarkDisplay.sortedForDisplay(reader.noteMarks), id: \.id) { mark in
                            markRow(mark)
                        }
                    }
                }
            }
            .navigationTitle(MarkDisplay.countText(reader.noteMarks.count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Chapter note…") {
                        dismiss()
                        onEditChapterNote()
                    }
                }
            }
            .sheet(item: $markDraft) { draft in
                markEditSheet(draft)
            }
        }
    }

    private func markRow(_ mark: Mark) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                onOpen(mark)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    if !mark.quote.isEmpty {
                        Text(mark.quote)
                            .font(.callout)
                            .italic()
                            .foregroundStyle(.secondary)
                    }
                    if !mark.body.isEmpty {
                        Text(mark.body)
                            .font(.callout)
                    }
                    let attribution = MarkDisplay.attribution(percent: mark.percent, at: mark.at)
                    if !attribution.isEmpty {
                        Text(attribution)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens this mark in the reader")
            Button {
                markDraft = MarkDraft(mark: mark)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Edit mark")
            Button {
                Task { await library.deleteMark(mark, reader: reader) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete mark")
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
                Spacer(minLength: 8)
                Button("Cancel", role: .cancel) { markDraft = nil }
                Button("Save") { saveMarkDraft(draft) }
            }
        }
        .padding()
        .presentationDetents([.height(200)])
    }

    private func saveMarkDraft(_ draft: MarkDraft) {
        Task {
            await library.updateMark(draft.mark, body: draft.body, reader: reader)
            markDraft = nil
        }
    }
}

/// The contemplative chapter note: a full-height editor over the chapter's
/// long-form body with word count, autosave on a debounce (the shared
/// `ReaderModel` machinery) plus on dismiss, and the chapter's marks
/// alongside — the reflection is written *from* the marks.
struct ChapterNoteEditorSheet: View {
    @Environment(LibraryModel.self) private var library
    @Environment(ReaderModel.self) private var reader

    @Environment(\.dismiss) private var dismiss
    @FocusState private var editorFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(reader.liveNoteWordCount) words")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(reader.noteStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: Binding(
                        get: { reader.noteBody },
                        set: { reader.noteBody = $0 }
                    ))
                    .focused($editorFocused)
                    .scrollContentBackground(.hidden)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
                    .padding(4)
                    if reader.noteBody.isEmpty {
                        Text("What did this chapter leave you with…")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 12)
                            .padding(.leading, 12)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxHeight: .infinity)

                marksStrip
            }
            .padding()
            .navigationTitle(reader.chapter?.title ?? "Chapter note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .presentationDetents([.large])
            .task(id: reader.chapter?.key) {
                await library.loadChapterNote(reader: reader)
                editorFocused = true
            }
            .onChange(of: reader.noteBody) {
                reader.noteEdited()
            }
            .onDisappear {
                reader.flushNoteSave()
            }
        }
    }

    @ViewBuilder
    private var marksStrip: some View {
        if !reader.noteMarks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(MarkDisplay.countText(reader.noteMarks.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(MarkDisplay.sortedForDisplay(reader.noteMarks), id: \.id) { mark in
                            VStack(alignment: .leading, spacing: 1) {
                                if !mark.quote.isEmpty {
                                    Text(mark.quote)
                                        .font(.caption)
                                        .italic()
                                        .foregroundStyle(.secondary)
                                }
                                if !mark.body.isEmpty {
                                    Text(mark.body)
                                        .font(.caption)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
                        }
                    }
                }
                .frame(maxHeight: 110)
            }
        }
    }
}
