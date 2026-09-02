import AppKit
import WebKit
import MarginsModel

/// Routes shell keyboard input through the same `ReaderKeymap` when focus is
/// in the SwiftUI shell (library list, detail). Events headed for the reader
/// webview (those are handled by the JS bridge) or a text field pass through
/// untouched, as do ⌘/⌃/⌥ combos so menus keep working.
@MainActor
final class ShellKeyboardController {
    private let model: LibraryModel
    private let reader: ReaderModel
    private let keymap = ReaderKeymap(mode: .library)
    // The NSEvent token is opaque and not Sendable-annotated; it is only
    // touched from the main actor and from deinit (exclusive access).
    nonisolated(unsafe) private var monitor: Any?

    init(model: LibraryModel, reader: ReaderModel) {
        self.model = model
        self.reader = reader
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            return event
        }

        guard let firstResponder = NSApp.keyWindow?.firstResponder else { return event }
        if firstResponder is NSTextView || isInsideWebView(firstResponder) {
            return event
        }

        guard let characters = event.characters, !characters.isEmpty,
              let key = characters.first
        else { return event }

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

    private func isInsideWebView(_ responder: Any) -> Bool {
        var view = responder as? NSView
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
            openSelectedBook()
            return true
        case .backToLibrary:
            guard reader.isOpen else { return false }
            reader.close()
            return true
        case .importBook:
            Task { await ImportPanel.run(model: model) }
            return true
        case .scroll, .scrollTop, .scrollBottom, .nextChapter, .previousChapter,
             .focusNotes, .search:
            // Reader-only or Part III actions; let the event through.
            return false
        }
    }

    private func openSelectedBook() {
        Task {
            await model.loadSelectedBook()
            guard let book = model.selectedBook, let first = book.chapters.first else { return }
            reader.open(book: book, chapter: first)
        }
    }
}
