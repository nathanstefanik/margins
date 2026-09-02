import AppKit
import WebKit
import MarginsModel

/// Routes keyboard and trackpad input for the whole app.
///
/// Keyboard: a single local `NSEvent` monitor sees every keyDown before
/// dispatch (including keys headed for the reader webview) and feeds them
/// through the shared `ReaderKeymap`. Reader actions are executed by
/// injecting calls into the reader page via `evaluateJavaScript`.
///
/// Trackpad: while the reader is open, two-finger scrolling accumulates and
/// turns pages (paginated content has no native overflow to scroll).
///
/// ⌘/⌃/⌥ combos and text-field typing pass through untouched so menus and
/// future text inputs keep working.
@MainActor
final class ShellKeyboardController {
    private let model: LibraryModel
    private let reader: ReaderModel
    private let keymap = ReaderKeymap(mode: .library)
    private static let pageScrollThreshold: CGFloat = 50
    // NSEvent monitor tokens are opaque and not Sendable-annotated; they are
    // only touched from the main actor and from deinit (exclusive access).
    nonisolated(unsafe) private var keyMonitor: Any?
    nonisolated(unsafe) private var scrollMonitor: Any?
    private var scrollAccumulator: CGFloat = 0

    init(model: LibraryModel, reader: ReaderModel) {
        self.model = model
        self.reader = reader
    }

    func start() {
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handleKey(event)
            }
        }
        if scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handleScroll(event)
            }
        }
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            return event
        }

        if let firstResponder = NSApp.keyWindow?.firstResponder, firstResponder is NSTextView {
            return event
        }

        guard let characters = event.characters, !characters.isEmpty,
              let key = characters.first
        else { return event }

        keymap.setMode(reader.isOpen ? .reader : .library)
        let keyEvent = ReaderKeyEvent(
            key: String(key),
            ctrl: flags.contains(.control),
            meta: flags.contains(.command),
            shift: flags.contains(.shift)
        )
        let actions = keymap.handle(keyEvent, now: ProcessInfo.processInfo.systemUptime)

        var handled = false
        for action in actions {
            handled = perform(action) || handled
        }
        return handled ? nil : event
    }

    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard reader.isOpen else { return event }
        // Ignore momentum: inertia should not flip through many pages.
        guard event.momentumPhase == .none else { return event }

        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        scrollAccumulator += abs(dx) > abs(dy) ? dx : dy

        if scrollAccumulator <= -Self.pageScrollThreshold {
            scrollAccumulator = 0
            turnPage(1)
        } else if scrollAccumulator >= Self.pageScrollThreshold {
            scrollAccumulator = 0
            turnPage(-1)
        }
        return event
    }

    @discardableResult
    private func perform(_ action: ReaderAction) -> Bool {
        switch action {
        case .moveLibrarySelection(let delta):
            model.moveLibrarySelection(delta)
            return true
        case .openSelectedBook:
            openSelectedBook()
            return true
        case .backToLibrary:
            guard reader.isOpen else { return false }
            reader.close()
            return true
        case .importBook:
            Task { await ImportPanel.run(model: model) }
            return true
        case .scroll(let delta):
            return evaluate("readerScrollBy(\(delta > 0 ? 1 : -1))")
        case .scrollTop:
            return evaluate("readerScrollTop()")
        case .scrollBottom:
            return evaluate("readerScrollBottom()")
        case .nextChapter:
            guard reader.nextChapter() != nil else { return false }
            return displayCurrentChapter()
        case .previousChapter:
            guard reader.previousChapter() != nil else { return false }
            return displayCurrentChapter()
        case .focusNotes, .search:
            // Notes and search arrive in Part III.
            return false
        }
    }

    private func displayCurrentChapter() -> Bool {
        guard let href = reader.chapter?.href else { return false }
        return evaluate("readerDisplay(\(ReaderController.javaScriptLiteral(href)))")
    }

    private func turnPage(_ direction: Int) {
        evaluate("readerScrollBy(\(direction))")
    }

    private func evaluate(_ script: String) -> Bool {
        guard let webView = readerWebView() else { return false }
        webView.evaluateJavaScript(script, completionHandler: nil)
        return true
    }

    private func readerWebView() -> WKWebView? {
        guard let contentView = NSApp.keyWindow?.contentView else { return nil }
        return findWebView(in: contentView)
    }

    private func findWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView {
            return webView
        }
        for subview in view.subviews {
            if let found = findWebView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func openSelectedBook() {
        Task {
            await model.loadSelectedBook()
            guard let book = model.selectedBook, let first = book.chapters.first else { return }
            reader.open(book: book, chapter: first)
        }
    }
}
