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

        // The search palette and the cheat sheet own Esc: their field
        // editor would otherwise consume the key before any SwiftUI
        // handler, so the monitor closes them directly (see
        // LibraryModel.searchOpen / helpOpen).
        if model.searchOpen, event.keyCode == 53 {
            model.requestSearchDismissal()
            return nil
        }
        if model.helpOpen, event.keyCode == 53 {
            model.requestHelpDismissal()
            return nil
        }

        // While a modal panel (e.g. the import open panel) runs, every key
        // belongs to it: typing must stay native and the keymap must not
        // act behind it.
        let modalPanelUp = NSApp.modalWindow != nil

        if let firstResponder = NSApp.keyWindow?.firstResponder, firstResponder is NSTextView {
            // Typing in a text field stays native — except Esc while writing
            // a note, which hands focus back to the book (Tauri semantics).
            if reader.isOpen, event.keyCode == 53, !modalPanelUp {
                reader.requestReaderFocus()
                return nil
            }
            return event
        }

        // Reader Esc backs out one layer at a time: the editor case above
        // returns focus to the book, this one closes the notes pane, and
        // the keymap's .backToLibrary below exits to the library.
        if reader.isOpen, reader.notesVisible, event.keyCode == 53, !modalPanelUp {
            reader.closeNotes()
            return nil
        }

        guard let characters = event.characters, let character = characters.first else {
            return event
        }

        // Function keys report private-use glyphs in `characters`; map the
        // ones we care about by key code so arrows and page keys route like
        // their keymap names.
        let key: String
        switch event.keyCode {
        case 123: key = "ArrowLeft"
        case 124: key = "ArrowRight"
        case 125, 121: key = "PageDown"
        case 126, 116: key = "PageUp"
        default: key = String(character)
        }

        keymap.setMode(
            model.searchOpen || model.helpOpen || modalPanelUp
                ? .modal
                : (reader.isOpen ? .reader : .library)
        )
        let keyEvent = ReaderKeyEvent(
            key: key,
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
        // (Phase is an OptionSet; compare via isEmpty so `.none` doesn't
        // resolve to Optional.none, which never matches.)
        guard event.momentumPhase.isEmpty else { return event }
        // Only page when the cursor is actually over the book; scrolling the
        // sidebar or notes pane keeps its native behavior.
        guard isCursorOverWebView(event) else { return event }

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

    private func isCursorOverWebView(_ event: NSEvent) -> Bool {
        guard let window = event.window, let contentView = window.contentView else { return false }
        let location = event.locationInWindow
        guard let hit = contentView.hitTest(contentView.convert(location, from: nil)) else { return false }
        var view: NSView? = hit
        while let current = view {
            if current is WKWebView {
                return true
            }
            view = current.superview
        }
        return false
    }

    @discardableResult
    private func perform(_ action: ReaderAction) -> Bool {
        switch action {
        case .moveLibrarySelection(let delta):
            model.moveLibrarySelection(delta)
            return true
        case .openSelectedBook:
            guard model.selectedBookID != nil else { return false }
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
            return ReaderController.evaluateInReader("readerScrollBy(\(delta > 0 ? 1 : -1))")
        case .scrollTop:
            return ReaderController.evaluateInReader("readerScrollTop()")
        case .scrollBottom:
            return ReaderController.evaluateInReader("readerScrollBottom()")
        case .nextChapter:
            guard reader.nextChapter() != nil else { return false }
            return displayCurrentChapter()
        case .previousChapter:
            guard reader.previousChapter() != nil else { return false }
            return displayCurrentChapter()
        case .focusNotes:
            guard reader.isOpen else { return false }
            reader.openNotes()
            return true
        case .search:
            model.requestSearch()
            return true
        case .help:
            model.requestHelp()
            return true
        }
    }

    private func displayCurrentChapter() -> Bool {
        guard let href = reader.chapter?.href else { return false }
        return ReaderController.evaluateInReader(
            "readerDisplay(\(ReaderController.javaScriptLiteral(href)))"
        )
    }

    private func turnPage(_ direction: Int) {
        ReaderController.evaluateInReader("readerScrollBy(\(direction))")
    }

    private func openSelectedBook() {
        guard let id = model.selectedBookID else { return }
        Task { await model.openBookResuming(id: id) }
    }
}
