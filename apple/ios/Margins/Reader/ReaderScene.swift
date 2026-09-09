import SwiftUI
import MarginsCore
import MarginsModel

/// The reader scene: the epub.js page full-bleed, with tap zones for
/// paging, a horizontally-swiping page turn, hardware-key support, and
/// immersive chrome. Note capture lives here too: the edit menu offers
/// Note/Highlight on selections, a persistent affordance anchors a
/// page-anchored mark, the chrome carries the chapter's mark count, and a
/// quiet end-of-chapter prompt offers the contemplative note. Saving
/// positions flushes on backgrounding: iOS will suspend you.
struct ReaderScene: View {
    @Environment(LibraryModel.self) private var library
    @Environment(ReaderModel.self) private var reader
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var chromeVisible = true
    @State private var typographyPresented = false
    @State private var tocPresented = false
    @State private var marksPresented = false
    @State private var editorPresented = false
    @State private var captureSelection: ReaderBridge.ReaderSelection?
    @State private var capturePresented = false
    @State private var flashVisible = false
    /// The chapter just finished (last page turned past); drives the quiet
    /// write-the-note prompt.
    @State private var finishedChapter: ChapterMeta?
    /// The representable's coordinator, handed over on creation; the
    /// chrome drives the page through it.
    @State private var bridge: ReaderBridge?
    /// The chapter whose note has been loaded. Highlight restore waits
    /// for both the note and the rendition (see `restoreHighlightsIfReady`).
    @State private var noteLoadedFor: String?
    /// The chapter whose highlights were last restored; the once-per-
    /// chapter guard keeps re-adding idempotent.
    @State private var highlightsRestoredFor: String?

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                IOSReaderWebView(model: library, reader: reader, bridge: $bridge, callbacks: callbacks)
                    .onTapGesture(coordinateSpace: .local) { location in
                        handleTap(at: location, width: proxy.size.width)
                    }
                    .gesture(pageSwipe)
            }
            .ignoresSafeArea(edges: .bottom)

            if chromeVisible {
                chrome
                    .transition(.opacity)
            }
            if let finished = finishedChapter {
                notePrompt(for: finished)
                    .transition(.opacity)
            }
            if flashVisible {
                flashBadge
            }
        }
        .overlay(alignment: .bottomLeading) {
            // VoiceOver path to every control: the chrome toggle and page
            // turns must never be gesture-only.
            Button {
                withAnimation { chromeVisible.toggle() }
            } label: {
                Image(systemName: chromeVisible ? "eye.slash" : "eye")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(chromeVisible ? .primary : .secondary)
                    .padding(10)
                    .background(.thinMaterial, in: .circle)
            }
            .opacity(chromeVisible ? 1 : 0.45)
            .padding(.leading, 14)
            .padding(.bottom, 60)
            .accessibilityLabel(chromeVisible ? "Hide reading controls" : "Show reading controls")
        }
        .overlay(alignment: .bottomTrailing) {
            captureAffordance
        }
        .animation(.easeOut(duration: 0.2), value: chromeVisible)
        .navigationTitle(reader.book?.title ?? "Reader")
        .navigationBarTitleDisplayMode(.inline)
        // The custom chrome carries the back affordance, the title, and
        // the actions and fades with `chromeVisible`; the system bar would
        // be a second, always-on header stacked on top of it (and push
        // the page content down).
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $typographyPresented) {
            TypographySheet(preferences: reader.preferences)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $tocPresented) {
            TOCSheet { chapter in
                jump(to: chapter)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $marksPresented) {
            MarksSheet(onEditChapterNote: {
                marksPresented = false
                editorPresented = true
            })
        }
        .sheet(isPresented: $editorPresented) {
            ChapterNoteEditorSheet()
        }
        .sheet(isPresented: $capturePresented) {
            CaptureSheet(selection: captureSelection, bridge: bridge, onCommitted: { _ in
                flash()
            })
        }
        .onChange(of: scenePhase) {
            // iOS suspends the app without warning: never lose position
            // (or a drafted note) to suspension.
            if scenePhase == .background {
                reader.flushPositionSave()
                reader.flushNoteSave()
            }
        }
        .task(id: reader.chapter?.key) {
            // The chapter note (body + marks) feeds the chrome count, the
            // sheets, and the highlight overlays; reloaded per chapter.
            await library.loadChapterNote(reader: reader)
            noteLoadedFor = reader.chapter?.key
            restoreHighlightsIfReady()
        }
        .onChange(of: reader.progress, { oldValue, newValue in
            detectChapterFinish(to: newValue)
            restoreHighlightsIfReady()
        })
        .onAppear {
            chromeVisible = true
        }
        #if DEBUG
        .task {
            await runDebugFixture()
        }
        #endif
    }

    // MARK: Callbacks

    private var callbacks: ReaderCallbacks {
        ReaderCallbacks(
            userPageTurn: { chromeVisible = false },
            captureRequest: { selection in
                captureSelection = selection
                capturePresented = true
            },
            highlightRequest: { selection in
                Task { highlight(selection) }
            }
        )
    }

    /// Highlight without a note: quote + empty body, committed instantly
    /// with a barest flash — the zero-typing case.
    private func highlight(_ selection: ReaderBridge.ReaderSelection) {
        guard let book = reader.book, let chapter = reader.chapter else { return }
        Task {
            if await library.appendMark(
                bookId: book.id,
                chapterKey: chapter.key,
                cfi: selection.cfiRange,
                percent: reader.bookPercent,
                quote: selection.text,
                body: "",
                reader: reader
            ) != nil {
                bridge?.restoreHighlights([selection.cfiRange])
                flash()
            }
            bridge?.clearSelection()
        }
    }

    private func flash() {
        withAnimation { flashVisible = true }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation { flashVisible = false }
        }
    }

    private var flashBadge: some View {
        Text("Mark saved")
            .font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .transition(.opacity)
            .accessibilityIdentifier("reader-flash")
    }

    // MARK: Highlight restore

    /// Paints the chapter's highlight overlays once both preconditions
    /// hold: the chapter's note is loaded (`noteLoadedFor` — the marks
    /// come from it) and the rendition is provably live for this chapter
    /// (`reader.progress != nil` — `open()` resets progress, and it is
    /// only set again by a `relocated` for the current chapter). A fixed
    /// timer cannot do this: first loads routinely outlast any constant
    /// sleep, and the overlay attach silently no-ops on an unready
    /// rendition.
    private func restoreHighlightsIfReady() {
        guard let key = reader.chapter?.key,
              noteLoadedFor == key,
              highlightsRestoredFor != key,
              reader.progress != nil
        else { return }
        highlightsRestoredFor = key
        bridge?.restoreHighlights(reader.noteMarks.compactMap(\.cfi))
    }

    // MARK: Capture affordance (no selection)

    /// The no-selection path: a small persistent affordance that fades but
    /// never disappears, anchoring the mark to the current page's CFI.
    private var captureAffordance: some View {
        Button {
            captureSelection = nil
            capturePresented = true
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(chromeVisible ? .primary : .secondary)
                .padding(10)
                .background(.thinMaterial, in: .circle)
        }
        .opacity(chromeVisible ? 1 : 0.45)
        .padding(.trailing, 14)
        .padding(.bottom, 60)
        .accessibilityLabel("New note at this page")
    }

    // MARK: End-of-chapter prompt

    /// Quiet and dismissible: offered once when the reader pages past a
    /// chapter's last page, silenced per finished chapter. The predicate
    /// (shared with the tests) demands the new chapter be the finished
    /// chapter's immediate successor, so TOC jumps don't trigger it.
    private func detectChapterFinish(to newProgress: ReaderProgress?) {
        defer {
            previousTurn = (reader.chapter?.key ?? "", newProgress)
        }
        // `reader.chapter` has already followed the relocation; the
        // previous snapshot holds the chapter that was just left.
        guard let previous = previousTurn,
              let finished = ReaderModel.finishedChapter(
                  previousKey: previous.key,
                  previousProgress: previous.progress,
                  newKey: reader.chapter?.key ?? "",
                  newProgress: newProgress,
                  chapters: reader.book?.chapters ?? []
              )
        else { return }
        let silencedKey = "notePrompt.dismissed.\(reader.book?.id ?? "").\(finished.key)"
        if !UserDefaults.standard.bool(forKey: silencedKey) {
            finishedChapter = finished
        }
    }

    @State private var previousTurn: (key: String, progress: ReaderProgress?)?

    private func notePrompt(for chapter: ChapterMeta) -> some View {
        VStack(spacing: 8) {
            Text("Finished \"\(chapter.title)\"")
                .font(.footnote.weight(.medium))
            Text("Write the chapter note while it's fresh?")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Not now") {
                    let bookID = reader.book?.id ?? ""
                    UserDefaults.standard.set(
                        true,
                        forKey: "notePrompt.dismissed.\(bookID).\(chapter.key)"
                    )
                    finishedChapter = nil
                }
                .buttonStyle(.bordered)
                Button("Write note") {
                    finishedChapter = nil
                    editorPresented = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: .rect(cornerRadius: 12))
        .padding(.bottom, 90)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .accessibilityElement(children: .combine)
    }

    // MARK: Chrome

    @ViewBuilder
    private var chrome: some View {
        VStack {
            topBar
            Spacer(minLength: 0)
            bottomBar
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Back to book")
            Text(reader.chapter?.title ?? reader.book?.title ?? "Reader")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button {
                tocPresented = true
            } label: {
                Image(systemName: "list.bullet")
            }
            .accessibilityLabel("Table of contents")
            Button {
                typographyPresented = true
            } label: {
                Image(systemName: "textformat")
            }
            .accessibilityLabel("Typography")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Button {
                pageBack(hideChrome: false)
            } label: {
                Image(systemName: "chevron.backward")
            }
            .accessibilityLabel("Previous page")
            Text(progressText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let percent = reader.bookPercent {
                ProgressView(value: percent, total: 100)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 160)
            }
            Spacer(minLength: 8)
            Button {
                marksPresented = true
            } label: {
                Image(systemName: reader.noteMarks.isEmpty ? "square.and.pencil" : "square.and.pencil.fill")
            }
            .accessibilityLabel(
                reader.noteMarks.isEmpty
                    ? "Marks"
                    : "\(reader.noteMarks.count) marks in this chapter"
            )
            Button {
                pageForward(hideChrome: false)
            } label: {
                Image(systemName: "chevron.forward")
            }
            .accessibilityLabel("Next page")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var progressText: String {
        guard let progress = reader.progress else { return "" }
        return "\(progress.page) / \(max(progress.totalPages, 1))"
    }

    // MARK: Input

    private func handleTap(at location: CGPoint, width: CGFloat) {
        // Thirds of the reader view itself — the window's width is wrong
        // the moment the reader is narrower (Split View, Slide Over,
        // Stage Manager).
        if location.x < width / 3 {
            pageBack()
        } else if location.x > width * 2 / 3 {
            pageForward()
        } else {
            chromeVisible.toggle()
        }
    }

    private var pageSwipe: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical) * 1.5 else { return }
                if horizontal < 0 {
                    pageForward()
                } else {
                    pageBack()
                }
            }
    }

    /// Explicit chrome controls never hide the chrome they live in; only
    /// page-surface input (taps, swipes, hardware keys) does.
    private func pageForward(hideChrome: Bool = true) {
        if hideChrome { chromeVisible = false }
        bridge?.pageForward()
    }

    private func pageBack(hideChrome: Bool = true) {
        if hideChrome { chromeVisible = false }
        bridge?.pageBack()
    }

    private func jump(to chapter: ChapterMeta) {
        guard let book = reader.book else { return }
        tocPresented = false
        chromeVisible = false
        reader.open(book: book, chapter: chapter)
        bridge?.jumpToChapter(chapter.jumpTarget)
    }

    #if DEBUG
    /// Development seams for simulator verification (no touch synthesis):
    /// `MARGINS_CAPTURE_FIXTURE=<text>` simulates a selection capture,
    /// `MARGINS_HIGHLIGHT_FIXTURE=1` commits a highlight at the current
    /// page, `MARGINS_EDITOR_FIXTURE=1` opens the chapter-note editor.
    private func runDebugFixture() async {
        guard let fixture = ProcessInfo.processInfo.environment["MARGINS_CAPTURE_FIXTURE"] else {
            if ProcessInfo.processInfo.environment["MARGINS_EDITOR_FIXTURE"] != nil {
                editorPresented = true
            } else if ProcessInfo.processInfo.environment["MARGINS_HIGHLIGHT_FIXTURE"] != nil {
                // Wait for the rendition so the page CFI is meaningful,
                // then advance to the first text page (the cover has no
                // text to highlight over).
                for _ in 0..<40 where reader.progress == nil {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                let firstKey = reader.chapter?.key
                bridge?.pageForward()
                for _ in 0..<40 where reader.chapter?.key == firstKey {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                // A relocated CFI is a point (zero-width); extend it into a
                // range over the first characters so the overlay can paint.
                var cfi = bridge?.currentPageCfi() ?? ""
                if !cfi.isEmpty, !cfi.contains(",/1:") {
                    cfi = String(cfi.dropLast()) + "/1:0,/1:5)"
                }
                highlight(ReaderBridge.ReaderSelection(cfiRange: cfi, text: "PART I"))
            }
            return
        }
        // Wait for the rendition so currentCfi is meaningful.
        for _ in 0..<40 where reader.progress == nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let cfi = bridge?.currentPageCfi() ?? "epubcfi(fixture)"
        print("[fixture] capture: cfi=\(cfi) text=\(fixture)")
        captureSelection = ReaderBridge.ReaderSelection(cfiRange: cfi, text: fixture)
        capturePresented = true
    }
    #endif
}

/// Sheet listing the book's spine; tapping jumps the reader there.
private struct TOCSheet: View {
    @Environment(ReaderModel.self) private var reader
    let onPick: (ChapterMeta) -> Void

    var body: some View {
        NavigationStack {
            List(reader.book?.chapters ?? []) { chapter in
                Button {
                    onPick(chapter)
                } label: {
                    HStack {
                        Text("\(chapter.index + 1)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 32, alignment: .trailing)
                        Text(chapter.title)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        if chapter.key == reader.chapter?.key {
                            Image(systemName: "bookmark.fill")
                                .font(.caption)
                                .foregroundStyle(.tint)
                                .accessibilityLabel("Current position")
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
