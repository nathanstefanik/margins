import Foundation

/// One row of the keyboard cheat sheet: the raw keymap key names bound to
/// one behavior, plus a human description. The raw names let tests verify
/// the sheet covers every key the keymap actually handles.
public struct KeyHelpEntry: Equatable, Sendable {
    public var keys: [String]
    public var description: String

    public init(keys: [String], description: String) {
        self.keys = keys
        self.description = description
    }
}

public struct KeyHelpGroup: Equatable, Sendable {
    public var name: String
    public var entries: [KeyHelpEntry]

    public init(name: String, entries: [KeyHelpEntry]) {
        self.name = name
        self.entries = entries
    }

    public var allKeys: [String] {
        entries.flatMap(\.keys)
    }
}

extension ReaderKeymap {
    /// The cheat-sheet model, grouped by context. The plan's test brute-
    /// forces `handle` and asserts every bound key appears here, so the
    /// sheet cannot drift from the keymap.
    public static func helpGroups() -> [KeyHelpGroup] {
        [
            KeyHelpGroup(name: "Library", entries: [
                KeyHelpEntry(keys: ["j", "k"], description: "Move selection"),
                KeyHelpEntry(keys: ["Enter"], description: "Open selected book"),
                KeyHelpEntry(keys: ["N"], description: "Compiled notes page"),
                KeyHelpEntry(keys: ["o"], description: "Import EPUB"),
                KeyHelpEntry(keys: ["/"], description: "Search notes"),
                KeyHelpEntry(keys: ["?"], description: "Keyboard shortcuts"),
            ]),
            KeyHelpGroup(name: "Reader", entries: [
                KeyHelpEntry(keys: ["j", "k"], description: "Turn pages"),
                KeyHelpEntry(keys: [" ", "ArrowRight", "PageDown"], description: "Next page"),
                KeyHelpEntry(keys: ["ArrowLeft", "PageUp"], description: "Previous page"),
                KeyHelpEntry(keys: ["g", "g"], description: "First page of chapter"),
                KeyHelpEntry(keys: ["G"], description: "Last page of chapter"),
                KeyHelpEntry(keys: ["n"], description: "Next chapter"),
                KeyHelpEntry(keys: ["p"], description: "Previous chapter"),
                KeyHelpEntry(keys: ["i", "Enter"], description: "Open and focus notes"),
                KeyHelpEntry(keys: ["Escape"], description: "Close notes pane; again → library"),
                KeyHelpEntry(keys: ["l"], description: "Back to library"),
                KeyHelpEntry(keys: ["/"], description: "Search notes"),
                KeyHelpEntry(keys: ["o"], description: "Import EPUB"),
                KeyHelpEntry(keys: ["?"], description: "Keyboard shortcuts"),
            ]),
            KeyHelpGroup(name: "Notes", entries: [
                KeyHelpEntry(keys: ["Escape"], description: "Back to the book (pane stays open)"),
                KeyHelpEntry(keys: ["⌘S"], description: "Save note (autosaved anyway)"),
            ]),
            KeyHelpGroup(name: "Global", entries: [
                KeyHelpEntry(keys: ["⌘O"], description: "Import EPUB"),
                KeyHelpEntry(keys: ["⌘F"], description: "Find"),
                KeyHelpEntry(keys: ["⌘="], description: "Bigger text"),
                KeyHelpEntry(keys: ["⌘-"], description: "Smaller text"),
                KeyHelpEntry(keys: ["⌘0"], description: "Reset text size"),
                KeyHelpEntry(keys: ["⌘,"], description: "Settings"),
                KeyHelpEntry(keys: ["Trackpad"], description: "Two-finger scroll turns pages"),
            ]),
        ]
    }
}
