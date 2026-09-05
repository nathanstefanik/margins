import Foundation

/// One forwarded key event, mirroring the payload reader.js sends from the
/// webview and what the shell monitor derives from NSEvent.
public struct ReaderKeyEvent: Equatable, Sendable {
    public var key: String
    public var ctrl: Bool
    public var meta: Bool
    public var shift: Bool

    public init(key: String, ctrl: Bool = false, meta: Bool = false, shift: Bool = false) {
        self.key = key
        self.ctrl = ctrl
        self.meta = meta
        self.shift = shift
    }
}

public enum ReaderKeymapMode: Equatable, Sendable {
    case library
    case reader
    /// A modal surface owns the keyboard (note search overlay, import
    /// panel): every key passes through untouched so Esc dismisses it and
    /// typing stays native, and the keymap must not act behind it.
    case modal
}

/// Actions the keymap produces; callers map them to UI behavior.
public enum ReaderAction: Equatable, Sendable {
    case moveLibrarySelection(delta: Int)
    case openSelectedBook
    case scroll(delta: Double)
    case scrollTop
    case scrollBottom
    case nextChapter
    case previousChapter
    case focusNotes
    case search
    case backToLibrary
    case importBook
    case help
    case openBookNotes
    case toggleNotesPageTab
    case backToBook
}

/// A small vim-style state machine mirroring `src/keymaps.ts`: `j`/`k`
/// move through the book in the reader or move the library selection in the
/// shell, arrows/space/PageUp/PageDown also page in the reader, `n`/`p`
/// change chapter, `gg`/`G` jump top/bottom, `i` focuses notes, `/` opens
/// search, `Esc`/`l` go back, `o` imports, `Enter` opens the selected book.
///
/// In the paginated flow `j`/`k`/arrows turn pages (the book has no vertical
/// overflow to scroll); `reader.js` interprets the scroll actions as
/// `rendition.next()`/`prev()` and top/bottom as first/last page.
///
/// Differences from the Tauri keymap (intentional): the pending-`g` chord
/// expires after one second, and the second `g` of the chord is handled
/// correctly (the TS `default:` branch was unreachable because `case "g"`
/// shadowed it). Typing guards (input/textarea targets) are the caller's
/// responsibility — the webview and the shell monitor each apply their own.
@MainActor
public final class ReaderKeymap {
    public static let pendingGTimeout: TimeInterval = 1.0

    public private(set) var mode: ReaderKeymapMode
    public private(set) var pendingG = false
    public private(set) var pendingGSince: TimeInterval?

    public init(mode: ReaderKeymapMode = .library) {
        self.mode = mode
    }

    public func setMode(_ mode: ReaderKeymapMode) {
        self.mode = mode
        pendingG = false
        pendingGSince = nil
    }

    /// Handles one key event; returns the actions to perform. `now` is a
    /// monotonic timestamp in seconds (injectable for tests).
    public func handle(_ event: ReaderKeyEvent, now: TimeInterval) -> [ReaderAction] {
        if event.ctrl || event.meta {
            return []
        }

        if mode == .modal {
            return []
        }

        if pendingG, let since = pendingGSince, now - since > Self.pendingGTimeout {
            pendingG = false
            pendingGSince = nil
        }

        switch event.key {
        case "j":
            return [mode == .library ? .moveLibrarySelection(delta: 1) : .scroll(delta: 80)]
        case "k":
            return [mode == .library ? .moveLibrarySelection(delta: -1) : .scroll(delta: -80)]
        case "g":
            guard mode == .reader else { return [] }
            if pendingG {
                pendingG = false
                pendingGSince = nil
                return [.scrollTop]
            }
            pendingG = true
            pendingGSince = now
            return []
        case "G":
            return mode == .reader ? [.scrollBottom] : []
        case "ArrowRight", "PageDown", " ":
            return mode == .reader ? [.scroll(delta: 80)] : []
        case "ArrowLeft", "PageUp":
            return mode == .reader ? [.scroll(delta: -80)] : []
        case "n":
            return mode == .reader ? [.nextChapter] : []
        case "p":
            return mode == .reader ? [.previousChapter] : []
        case "i":
            return mode == .reader ? [.focusNotes] : []
        case "/":
            return [.search]
        case "?":
            return [.help]
        case "l", "Escape":
            if mode == .reader {
                return [.backToLibrary]
            }
            // Book view: pops back from the compiled notes page. Elsewhere
            // on the book detail it is a no-op (the caller returns false
            // and the key passes through untouched).
            if mode == .library {
                return [.backToBook]
            }
            return []
        case "N":
            // Book view (reader closed): the compiled notes page. Consistent
            // with the Tauri app's `N` / `:notes`.
            return mode == .library ? [.openBookNotes] : []
        case "t":
            // On the compiled notes page: flip between outline and
            // contents. Only meaningful there; the caller no-ops otherwise.
            return mode == .library ? [.toggleNotesPageTab] : []
        case "o":
            return [.importBook]
        case "Enter":
            // Library: open the selected book. Reader: enter the notes
            // focus (nvim-style `i`/Enter in, Esc out; repeated presses
            // never type into the editor — Esc leaves it).
            return mode == .library ? [.openSelectedBook] : [.focusNotes]
        default:
            pendingG = false
            pendingGSince = nil
            return []
        }
    }
}
