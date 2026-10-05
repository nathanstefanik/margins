import MarginsCore
import MarginsModel
import SwiftUI

struct NotesPane: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ReaderModel.self) private var reader
    @FocusState private var editorFocused: Bool
    @State private var markDraft: MarkDraft?

    /// The resolved reading paper — the pane is part of the page, not
    /// system chrome.
    private var theme: ReaderTheme { reader.preferences.theme }

    /// The reader face at the size that matches the page's body text at the
    /// default text size (110% of a 15pt base ≈ 16.5pt at 110% — the note
    /// should read like the prose it annotates).
    private var editorFont: Font {
        .custom(reader.preferences.typeface.familyName, size: 15, relativeTo: .body)
    }

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
        .background(Paper.background(theme))
        .foregroundStyle(Paper.ink(theme))
        // The paper decides legibility: caret, selection, scroll
        // indicators, and buttons all follow the pane's scheme, not the
        // system's — dark paper needs a dark pane's controls either way.
        .environment(\.colorScheme, theme.palette.isDark ? .dark : .light)
        .task(id: reader.chapter?.key) {
            await model.loadChapterNote(reader: reader)
        }
        .onChange(of: reader.noteBody) {
            reader.noteEdited()
        }
        // `.task` fires on mount too — unlike `.onChange`, which misses the
        // request that opened the pane in the same update (openNotes bumps
        // the counter before the pane exists to observe it).
        .task(id: reader.notesFocusRequest) {
            await Task.yield()
            editorFocused = true
        }
        .onChange(of: reader.readerFocusRequest) {
            editorFocused = false
        }
        .onChange(of: reader.chapter?.key) {
            // A mark draft belongs to one chapter; switching chapters must
            // not aim the pending update at the new one.
            markDraft = nil
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
                .foregroundStyle(Paper.secondaryInk(theme))
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
                        .font(.custom(reader.preferences.typeface.familyName, size: 13, relativeTo: .callout).italic())
                        .foregroundStyle(Paper.secondaryInk(theme))
                        .textSelection(.enabled)
                }
                if !mark.body.isEmpty {
                    Text(mark.body)
                        .font(.custom(reader.preferences.typeface.familyName, size: 13, relativeTo: .callout))
                        .textSelection(.enabled)
                }
                let attribution = MarkDisplay.attribution(percent: mark.percent, at: mark.at)
                if !attribution.isEmpty {
                    Text(attribution)
                        .font(.caption2)
                        .foregroundStyle(Paper.secondaryInk(theme).opacity(0.7))
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
            .foregroundStyle(Paper.secondaryInk(theme))
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
            Text(
                ReaderModel.noteHeaderText(
                    chapterIndex: reader.chapter.map { Int($0.index) } ?? 0,
                    chapterTitle: reader.chapter?.title
                )
            )
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(reader.chapter?.title ?? "")
            Spacer(minLength: 8)
            Text("\(reader.liveNoteWordCount) words")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Paper.secondaryInk(theme))
            saveStatus
        }
    }

    /// Fixed-position save state: the text fades in and out, but the space
    /// it occupies never changes, so nothing jumps when the dirty state does.
    private var saveStatus: some View {
        Text(reader.noteStatusText)
            .font(.caption)
            .foregroundStyle(Paper.secondaryInk(theme))
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
            // No box: the note sits on the paper itself, like a margin note
            // on the same sheet as the page.
            TextEditor(text: $reader.noteBody)
                .focused($editorFocused)
                .font(editorFont)
                .scrollContentBackground(.hidden)
            if reader.noteBody.isEmpty {
                Text("What stood out? Questions, reactions, and ideas worth returning to…")
                    .font(editorFont)
                    .foregroundStyle(Paper.secondaryInk(theme))
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
