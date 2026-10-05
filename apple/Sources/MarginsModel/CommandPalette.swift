import Foundation
import MarginsCore

/// The ⌘K "Go To…" palette's item model — pure so the grouping, ordering,
/// and state-dependent commands are testable without a view. The macOS
/// overlay renders `sections(for:in:)`; the `Action` enum stays closure-free
/// so the app maps each case onto its existing commands.
public enum CommandPalette {
    public enum Group: String, CaseIterable, Equatable, Sendable {
        case books
        case chapters
        case commands
    }

    /// Everything the palette can do. Each case maps onto an action the app
    /// already has — the model carries no behaviour.
    public enum Action: Equatable, Sendable {
        case openBook(id: String)
        case openChapter(bookId: String, chapterKey: String, fragment: String?)
        case run(Command)
    }

    /// Commands gated by state are only offered when valid — e.g. Bookmarks
    /// needs an open reader.
    public enum Command: Equatable, Hashable, Sendable {
        case importBook
        case toggleSidebar
        case notesPage
        case bookmarks
        case searchNotes
        case keyboardShortcuts
        case settings
        case paper(ReaderTheme)
        case paperMatchSystem
        case toggleJustify
        case toggleOrnaments
        case pageIndicator(ReaderPageIndicator)
        case toggleFocus

        /// Stable identifier for result ids — payloads rule out rawValue.
        var id: String {
            switch self {
            case .importBook: "importBook"
            case .toggleSidebar: "toggleSidebar"
            case .notesPage: "notesPage"
            case .bookmarks: "bookmarks"
            case .searchNotes: "searchNotes"
            case .keyboardShortcuts: "keyboardShortcuts"
            case .settings: "settings"
            case .paper(let theme): "paper-\(theme.rawValue)"
            case .paperMatchSystem: "paperMatchSystem"
            case .toggleJustify: "toggleJustify"
            case .toggleOrnaments: "toggleOrnaments"
            case .pageIndicator(let mode): "indicator-\(mode.rawValue)"
            case .toggleFocus: "toggleFocus"
            }
        }
    }

    public struct Item: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var subtitle: String
        public var group: Group
        public var action: Action

        public init(id: String, title: String, subtitle: String, group: Group, action: Action) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.group = group
            self.action = action
        }
    }

    /// What the builder needs to know: the shelf order for books, the book
    /// whose chapters go in the palette (the open one, else the selected
    /// one), and the flags that decide which commands are valid now.
    public struct Context: Sendable {
        public var books: [BookSummary]
        public var chaptersBook: BookMeta?
        public var hasSelectedBook: Bool
        public var readerOpen: Bool
        public var readerFocused: Bool
        public var justify: Bool
        public var ornaments: Bool

        public init(
            books: [BookSummary],
            chaptersBook: BookMeta?,
            hasSelectedBook: Bool,
            readerOpen: Bool,
            readerFocused: Bool = false,
            justify: Bool,
            ornaments: Bool
        ) {
            self.books = books
            self.chaptersBook = chaptersBook
            self.hasSelectedBook = hasSelectedBook
            self.readerOpen = readerOpen
            self.readerFocused = readerFocused
            self.justify = justify
            self.ornaments = ornaments
        }
    }

    /// The most results the overlay will show.
    public static let resultLimit = 30

    /// Books on an empty query: a quick-pick strip, not the whole library.
    public static let emptyQueryBookLimit = 5

    // MARK: Items

    /// Every item the palette could offer in this state.
    public static func items(for context: Context) -> [Item] {
        var items: [Item] = []
        for book in context.books {
            items.append(
                Item(
                    id: "book-\(book.id)",
                    title: book.title,
                    subtitle: book.author,
                    group: .books,
                    action: .openBook(id: book.id)))
        }
        if let book = context.chaptersBook {
            let outline = ContentsOutline.build(from: book.chapters)
            for row in outline.body {
                let subtitle: String
                if case .chapter(let number) = row.kind {
                    subtitle = "Chapter \(number)"
                } else {
                    subtitle = "Heading"
                }
                items.append(
                    Item(
                        id: "chapter-\(row.id)",
                        title: row.title,
                        subtitle: subtitle,
                        group: .chapters,
                        action: .openChapter(
                            bookId: book.id,
                            chapterKey: row.chapter.key,
                            fragment: row.jumpFragment)))
            }
        }
        items.append(contentsOf: commandItems(for: context))
        return items
    }

    private static func commandItems(for context: Context) -> [Item] {
        var items: [Item] = [
            command(.importBook, "Import EPUB…", "File"),
            command(.toggleSidebar, "Toggle Sidebar", "View"),
            command(.searchNotes, "Search Notes", "Notes"),
            command(.keyboardShortcuts, "Keyboard Shortcuts", "Help"),
            command(.settings, "Settings…", "Margins"),
        ]
        if context.hasSelectedBook {
            items.append(command(.notesPage, "Book Notes", "Notes"))
        }
        if context.readerOpen {
            items.append(command(.bookmarks, "Bookmarks", "Reader"))
            items.append(
                command(.toggleFocus, "Focus Mode", context.readerFocused ? "On" : "Off"))
        }
        for theme in ReaderTheme.allCases {
            items.append(command(.paper(theme), "Paper: \(theme.name)", "Reading"))
        }
        items.append(command(.paperMatchSystem, "Paper: Match System", "Reading"))
        items.append(command(.toggleJustify, "Justify Text", context.justify ? "On" : "Off"))
        items.append(
            command(.toggleOrnaments, "Chapter Ornaments", context.ornaments ? "On" : "Off"))
        for mode in ReaderPageIndicator.allCases {
            items.append(
                command(.pageIndicator(mode), "Page Indicator: \(mode.name)", "Reading"))
        }
        return items
    }

    private static func command(_ command: Command, _ title: String, _ subtitle: String) -> Item {
        Item(
            id: "command-\(command.id)",
            title: title,
            subtitle: subtitle,
            group: .commands,
            action: .run(command))
    }

    // MARK: Filtering and grouping

    /// The sections to show, in palette order (Books, Chapters, Commands).
    /// An empty query offers the first few books and every valid command;
    /// a query fuzzy-filters all groups, sorting each by score with the
    /// title dominating the subtitle, capped at `resultLimit` total.
    public static func sections(for query: String, in items: [Item]) -> [(group: Group, items: [Item])] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            var sections: [(Group, [Item])] = []
            let books = items.filter { $0.group == .books }.prefix(emptyQueryBookLimit)
            if !books.isEmpty { sections.append((.books, Array(books))) }
            let commands = items.filter { $0.group == .commands }
            if !commands.isEmpty { sections.append((.commands, commands)) }
            return sections
        }

        var scored: [(item: Item, score: Int, order: Int)] = []
        for (index, item) in items.enumerated() {
            if let title = FuzzyMatch.score(query, in: item.title) {
                scored.append((item, title, index))
            } else if let subtitle = FuzzyMatch.score(query, in: item.subtitle) {
                // Subtitle matches rank below any title match at the same
                // score.
                scored.append((item, subtitle - 12, index))
            }
        }
        var result: [(Group, [Item])] = []
        var total = 0
        for group in Group.allCases {
            let groupItems = scored
                .filter { $0.item.group == group }
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            let remaining = resultLimit - total
            let shown = groupItems.prefix(remaining).map(\.item)
            if !shown.isEmpty {
                result.append((group, shown))
                total += shown.count
            }
        }
        return result
    }
}
