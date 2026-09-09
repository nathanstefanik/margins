import SwiftUI
import MarginsCore
import MarginsModel

/// The reader's paper palette, matching `reader.html` (`#f4f1ea` / `#111`).
/// The Apple-target `Paper` enum lives in the macOS app target, which the
/// iOS app does not link.
private enum ReaderPaper {
    static let background = Color(red: 244 / 255, green: 241 / 255, blue: 234 / 255)
}

/// The reader scene, styled after Apple Books: a full-bleed paper page
/// with immersive chrome. Tap the page's edges to turn, its middle to
/// show or hide the controls; swipe to page; hardware keys work too.
/// The chrome carries the back button, chapter marks and quick capture up
/// top, and Contents / a position slider / typography below — the slider
/// scrubs to an exact CFI once the book's locations are generated, and
/// falls back to the nearest chapter before that. Note capture lives here
/// too: the edit menu offers Note/Highlight on selections, and a quiet
/// end-of-chapter prompt offers the contemplative note. Saving positions
/// flushes on backgrounding: iOS will suspend you.
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
    /// Whole-book locations are generated in the background after the
    /// book opens; once ready the scrubber jumps to an exact CFI.
    @State private var locationsReady = false

    var body: some View {
        ZStack {
            ReaderPaper.background.ignoresSafeArea()
            readerSurface
        }
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

    /// The reading surface. The chrome, the end-of-chapter prompt, and the
    /// flash badge are overlays of the webview itself — as ZStack siblings
    /// of a full-bleed `UIViewRepresentable` they render above it but
    /// never receive touches (the webview's UIKit frame claims them
    /// first), which leaves the whole chrome dead. The webview itself
    /// stays inside the safe area; the paper in the ZStack paints the
    /// status-bar and home-indicator zones, so the page still reads as
    /// one full-bleed sheet.
    private var readerSurface: some View {
        IOSReaderWebView(model: library, reader: reader, bridge: $bridge, callbacks: callbacks)
            .accessibilityLabel("Reading page")
            .accessibilityAction(named: "Turn page forward") {
                pageForward()
            }
            .accessibilityAction(named: "Turn page back") {
                pageBack()
            }
            .accessibilityAction(named: "Toggle reading controls") {
                withAnimation { chromeVisible.toggle() }
            }
            .overlay {
                ZStack {
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
                .animation(.easeOut(duration: 0.2), value: chromeVisible)
                .animation(.easeOut(duration: 0.2), value: flashVisible)
            }
    }

    // MARK: Callbacks

    private var callbacks: ReaderCallbacks {
        ReaderCallbacks(
            userPageTurn: { chromeVisible = false },
            pageTap: { x, _ in
                handleTap(x: x)
            },
            pageSwipe: { forward in
                chromeVisible = false
                if forward {
                    bridge?.pageForward()
                } else {
                    bridge?.pageBack()
                }
            },
            locationsReady: {
                locationsReady = true
            },
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

    // MARK: Chrome (Apple Books style)

    @ViewBuilder
    private var chrome: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            bottomBar
        }
    }

    /// Back, centered chapter title, and the chapter's annotation
    /// affordances — the Books top bar, with capture where Books keeps
    /// its share button.
    private var topBar: some View {
        HStack(spacing: 4) {
            chromeButton("chevron.left", "Back to book") {
                dismiss()
            }
            Spacer(minLength: 8)
            Text(reader.chapter?.title ?? reader.book?.title ?? "Reader")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            chromeButton(
                reader.noteMarks.isEmpty ? "bookmark" : "bookmark.fill",
                reader.noteMarks.isEmpty
                    ? "Marks in this chapter"
                    : "\(reader.noteMarks.count) marks in this chapter"
            ) {
                marksPresented = true
            }
            chromeButton("square.and.pencil", "New note at this page") {
                captureSelection = nil
                capturePresented = true
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .background(barBackground(top: true))
    }

    /// Contents, the position scrubber, and typography — the Books bottom
    /// bar. The scrub track is built from SwiftUI primitives rather than
    /// `Slider`: `Slider` is UISlider-backed, and a platform view stacked
    /// over the web view's platform layer loses its touches to it.
    private var bottomBar: some View {
        VStack(spacing: 2) {
            HStack(spacing: 10) {
                chromeButton("list.bullet", "Table of contents") {
                    tocPresented = true
                }
                scrubTrack
                chromeButton("textformat", "Typography") {
                    typographyPresented = true
                }
            }
            HStack {
                Text(pageText)
                Spacer(minLength: 16)
                Text(percentText)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(barBackground(top: false))
    }

    /// The whole-book position scrubber: tap anywhere on the track to
    /// jump there — an exact CFI once the book's locations are ready, the
    /// nearest chapter before that. Built from SwiftUI primitives rather
    /// than `Slider` (UISlider-backed platform views stacked over the web
    /// view lose their touches), and tap-driven because the web view's
    /// gesture recognizers cancel cross-host drags mid-gesture.
    private var scrubTrack: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let value = reader.bookPercent ?? 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.15))
                    .frame(height: 4)
                Capsule()
                    .fill(.tint)
                    .frame(width: max(0, width * value / 100), height: 4)
                Circle()
                    .fill(ReaderPaper.background)
                    .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 2)
                    .frame(width: 22, height: 22)
                    .offset(x: max(0, min(width - 22, width * value / 100 - 11)))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(.rect)
            .onTapGesture(coordinateSpace: .local) { location in
                commitScrub(max(min(location.x / width * 100, 100), 0))
            }
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Reading position")
        .accessibilityValue(percentText)
        .accessibilityAdjustableAction { direction in
            let current = reader.bookPercent ?? 0
            switch direction {
            case .increment: commitScrub(min(current + 5, 100))
            case .decrement: commitScrub(max(current - 5, 0))
            @unknown default: return
            }
        }
    }

    /// A chrome button on paper: Books renders plain dark icons with
    /// full-size touch targets.
    private func chromeButton(
        _ systemImage: String,
        _ label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .frame(minWidth: 40, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// The bars sit on the same paper as the page, with a hairline toward
    /// the content; each bleeds under its screen edge.
    private func barBackground(top: Bool) -> some View {
        Rectangle()
            .fill(ReaderPaper.background)
            .overlay(alignment: top ? .bottom : .top) {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 0.5)
            }
            .ignoresSafeArea(edges: top ? .top : .bottom)
    }

    private var pageText: String {
        guard let progress = reader.progress, progress.totalPages > 0 else { return "" }
        return "Page \(progress.page) of \(progress.totalPages)"
    }

    private var percentText: String {
        String(format: "%.0f%%", reader.bookPercent ?? 0)
    }

    /// Scrub finished at `percent` of the book: an exact CFI jump when the
    /// book's locations are ready, otherwise the nearest chapter.
    private func commitScrub(_ percent: Double) {
        guard let book = reader.book else { return }
        if locationsReady {
            bridge?.scrubToPercent(percent)
            return
        }
        let count = book.chapters.count
        guard count > 0 else { return }
        let index = min(Int(percent / 100 * Double(count)), count - 1)
        jump(to: book.chapters[index], hideChrome: false)
    }

    // MARK: Input

    /// Tap zones in thirds of the reader view (the page reports tap
    /// fractions itself): edges turn pages, the middle toggles the chrome.
    private func handleTap(x: Double) {
        if x < 1.0 / 3.0 {
            pageBack()
        } else if x > 2.0 / 3.0 {
            pageForward()
        } else {
            withAnimation { chromeVisible.toggle() }
        }
    }

    private func pageForward() {
        chromeVisible = false
        bridge?.pageForward()
    }

    private func pageBack() {
        chromeVisible = false
        bridge?.pageBack()
    }

    private func jump(to chapter: ChapterMeta, hideChrome: Bool = true) {
        guard let book = reader.book else { return }
        tocPresented = false
        if hideChrome {
            chromeVisible = false
        }
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
