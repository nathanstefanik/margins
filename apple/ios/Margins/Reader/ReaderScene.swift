import SwiftUI
import MarginsCore
import MarginsModel

/// The reader scene: the epub.js page full-bleed, with tap zones for
/// paging, a horizontally-swiping page turn, hardware-key support, and
/// book-like chrome. The resting screen is a printed spread — chapter
/// title centered at the top of the paper, page number at the bottom —
/// and a center tap reveals back, hamburger, and the new-note affordance
/// as overlays that never reflow the page. Note capture lives here too:
/// the edit menu offers Note/Highlight on selections, the chrome carries
/// the note button, and a quiet end-of-chapter prompt offers the
/// contemplative note. Saving positions flushes on backgrounding: iOS
/// will suspend you.
struct ReaderScene: View {
    @Environment(LibraryModel.self) private var library
    @Environment(ReaderModel.self) private var reader
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// The page rests without chrome; a center tap reveals it.
    @State private var chromeVisible = false
    @State private var settingsPresented = false
    @State private var tocPresented = false
    @State private var marksPresented = false
    @State private var editorPresented = false
    /// The hamburger menu's chosen destination, presented after the menu
    /// dismisses (sheet-on-sheet presentations queue through here).
    @State private var pendingDestination: ReaderDestination?
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
    /// Last `passageJumpGeneration` applied via JS/reload, so the initial
    /// URL load is not doubled when the reader is first pushed.
    @State private var appliedJumpGeneration = 0
    /// Book currently loaded in the webview; a passage jump to another
    /// book reloads the scheme URL instead of displaying a foreign CFI.
    @State private var loadedBookId: String?

    var body: some View {
        ZStack {
            Color(red: 244 / 255, green: 241 / 255, blue: 234 / 255)
                .ignoresSafeArea()
            GeometryReader { proxy in
                IOSReaderWebView(model: library, reader: reader, bridge: $bridge, callbacks: callbacks)
                    .onTapGesture(coordinateSpace: .local) { location in
                        handleTap(at: location, width: proxy.size.width)
                    }
                    .gesture(pageSwipe)
                    .overlay(alignment: .top) { headerOverlay }
                    .overlay(alignment: .bottom) { footerOverlay }
                    .accessibilityAction(named: Text("Show controls")) {
                        chromeVisible = true
                    }
                    .accessibilityAction(named: Text("New note")) {
                        newNote()
                    }
            }
            if let finished = finishedChapter {
                notePrompt(for: finished)
                    .transition(.opacity)
            }
            if flashVisible {
                flashBadge
            }
        }
        .animation(.easeOut(duration: 0.2), value: chromeVisible)
        .navigationTitle(reader.book?.title ?? "Reader")
        .navigationBarTitleDisplayMode(.inline)
        // The custom chrome carries the back affordance, the title, and
        // the actions and fades with `chromeVisible`; the system bar would
        // be a second, always-on header stacked on top of it (and push
        // the page content down).
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $settingsPresented, onDismiss: presentPendingDestination) {
            ReaderSettingsSheet(preferences: reader.preferences) { destination in
                pendingDestination = destination
                settingsPresented = false
            }
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
            }, onOpen: { mark in
                marksPresented = false
                jumpToMark(mark)
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
            // The chapter note (body + marks) feeds the sheets, the
            // highlight overlays, and the chrome; reloaded per chapter.
            await library.loadChapterNote(reader: reader)
            noteLoadedFor = reader.chapter?.key
            restoreHighlightsIfReady()
        }
        .onChange(of: reader.progress, { oldValue, newValue in
            detectChapterFinish(to: newValue)
            restoreHighlightsIfReady()
        })
        .onAppear {
            appliedJumpGeneration = library.passageJumpGeneration
            loadedBookId = reader.book?.id
        }
        .onChange(of: library.passageJumpGeneration) {
            applyPassageJumpIfNeeded()
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

    // MARK: Chrome overlays

    /// A 44pt hit target that survives WKWebView's bounds: the same class
    /// of bug as the old dead eye/note buttons.
    private func chromeButton(
        _ systemName: String,
        _ label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// The running head: chapter title centered at the top of the paper,
    /// with back / new note / hamburger fading in around it. The title is
    /// not hit-testable — a tap on it belongs to the page thirds.
    private var headerOverlay: some View {
        ZStack {
            Text(reader.chapter?.title ?? reader.book?.title ?? "Reader")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, chromeVisible ? 52 : 24)
                .padding(.trailing, chromeVisible ? 96 : 24)
                .allowsHitTesting(false)
            if chromeVisible {
                HStack(spacing: 0) {
                    chromeButton("chevron.left", "Back to book") { dismiss() }
                    Spacer(minLength: 0)
                    chromeButton("square.and.pencil", "New note at this page") {
                        newNote()
                    }
                    chromeButton("line.3.horizontal", "Reader menu") {
                        settingsPresented = true
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(height: 44)
    }

    /// The running foot: this chapter's paginated page number, expanding
    /// to `12 of 40` while the chrome is up. Never hit-tested, so a
    /// center tap over it still toggles the chrome.
    private var footerOverlay: some View {
        Text(pageText)
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(height: 44)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    /// Chapter-local page counts (what epub.js reports); the app has no
    /// whole-book page total, only a percent.
    private var pageText: String {
        guard let progress = reader.progress else { return "" }
        return chromeVisible
            ? "\(progress.page) of \(max(progress.totalPages, 1))"
            : "\(progress.page)"
    }

    private func newNote() {
        captureSelection = nil
        capturePresented = true
    }

    private func presentPendingDestination() {
        switch pendingDestination {
        case .contents: tocPresented = true
        case .marks: marksPresented = true
        case .chapterNote: editorPresented = true
        case nil: break
        }
        pendingDestination = nil
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
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .accessibilityElement(children: .combine)
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

    /// Page-surface input (taps, swipes, hardware keys) always hides the
    /// chrome; only the center tap toggles it back.
    private func pageForward() {
        chromeVisible = false
        bridge?.pageForward()
    }

    private func pageBack() {
        chromeVisible = false
        bridge?.pageBack()
    }

    private func jump(to chapter: ChapterMeta) {
        guard let book = reader.book else { return }
        tocPresented = false
        chromeVisible = false
        reader.open(book: book, chapter: chapter)
        bridge?.jumpToChapter(chapter.jumpTarget)
    }

    /// Lands on a mark's CFI (or stays put for a page-anchored mark with
    /// no range). The marks sheet is always the current chapter.
    private func jumpToMark(_ mark: Mark) {
        if let cfi = mark.cfi, !cfi.isEmpty {
            chromeVisible = false
            bridge?.jumpToChapter(cfi)
        }
    }

    /// Retarget an already-visible reader after `openPassage`. Same book:
    /// `rendition.display` of the CFI or chapter href. Different book:
    /// reload the scheme URL (it carries the book id and resume CFI).
    private func applyPassageJumpIfNeeded() {
        guard bridge != nil,
              appliedJumpGeneration != library.passageJumpGeneration
        else { return }
        appliedJumpGeneration = library.passageJumpGeneration
        let bookId = reader.book?.id
        if loadedBookId != bookId {
            highlightsRestoredFor = nil
            noteLoadedFor = nil
            loadedBookId = bookId
            bridge?.loadCurrentBook()
            return
        }
        if let cfi = reader.resumeCfi, !cfi.isEmpty {
            bridge?.jumpToChapter(cfi)
        } else if let chapter = reader.chapter {
            bridge?.jumpToChapter(chapter.jumpTarget)
        }
        chromeVisible = false
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
