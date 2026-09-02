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
}

/// A small vim-style state machine mirroring `src/keymaps.ts`: `j`/`k`
/// scroll in the reader or move the library selection in the shell, `n`/`p`
/// change chapter, `gg`/`G` jump top/bottom, `i` focuses notes, `/` opens
/// search, `Esc`/`l` go back, `o` imports, `Enter` opens the selected book.
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
            if pendingG {
                pendingG = false
                pendingGSince = nil
                return [.scrollTop]
            }
            pendingG = true
            pendingGSince = now
            return []
        case "G":
            return [.scrollBottom]
        case "n":
            return [.nextChapter]
        case "p":
            return [.previousChapter]
        case "i":
            return [.focusNotes]
        case "/":
            return [.search]
        case "l", "Escape":
            return [.backToLibrary]
        case "o":
            return [.importBook]
        case "Enter":
            return mode == .library ? [.openSelectedBook] : []
        default:
            pendingG = false
            pendingGSince = nil
            return []
        }
    }
}
