import MarginsCore
import MarginsModel
import SwiftUI

/// The ⌘K "Go To…" palette — a Spotlight-style overlay in the same shape
/// as `SearchOverlay`: click-away scrim, one field that keeps focus for
/// the palette's whole life, ↑/↓ (or ⌃N/⌃P) moving a wrapped selection,
/// Enter running it, Esc dismissing (the shell key monitor owns Esc).
/// Items come from `CommandPalette` in MarginsModel; this view only maps
/// actions onto the app's existing commands.
struct CommandPaletteOverlay: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ReaderModel.self) private var reader
    /// Same focused value `MarginsCommands` reads, so Toggle Sidebar works
    /// from the palette exactly as ⌘B does.
    @FocusedValue(\.sidebarVisibility) private var sidebarVisibility
    @Environment(\.openSettings) private var openSettings
    @FocusState private var fieldFocused: Bool

    @State private var query = ""
    @State private var selection = 0
    @State private var keyboardScrollTarget: Int?
    /// The palette's own keyDown monitor: the field editor claims Return
    /// before SwiftUI's `onSubmit`/`onKeyPress` can see it, so Enter,
    /// arrows, and ⌃N/⌃P are intercepted here while the palette is up.
    @State private var keyMonitor: Any?

    private typealias Item = CommandPalette.Item

    var body: some View {
        ZStack {
            // Click-away scrim: a click anywhere outside the panel closes.
            Color.clear
                .contentShape(.rect)
                .onTapGesture { model.requestPaletteDismissal() }

            VStack(alignment: .leading, spacing: 0) {
                fieldRow
                Divider()
                content
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
            .frame(width: 600)
            .padding(.top, 48)
            // Keep clicks on the panel's blank areas from closing it.
            .contentShape(.rect)
            .onTapGesture {}
        }
        .onAppear {
            // The reader's webview yields first-responder a beat after the
            // overlay mounts; focus on the next turn so typing lands.
            DispatchQueue.main.async { fieldFocused = true }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch event.keyCode {
                case 36, 76:  // Return / keypad Enter
                    run(flatItems[safe: selection] ?? flatItems.first)
                    return nil
                case 126:  // ↑
                    moveSelection(-1)
                    return nil
                case 125:  // ↓
                    moveSelection(1)
                    return nil
                default:
                    // Vim hands: ⌃N/⌃P move the selection like ↓/↑.
                    if event.modifierFlags.contains(.control),
                        let character = event.charactersIgnoringModifiers?.first
                    {
                        switch character {
                        case "n":
                            moveSelection(1)
                            return nil
                        case "p":
                            moveSelection(-1)
                            return nil
                        default:
                            break
                        }
                    }
                    return event
                }
            }
        }
        .onDisappear {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
            keyMonitor = nil
        }
        .onExitCommand {
            model.requestPaletteDismissal()
        }
    }

    // MARK: Items

    private var context: CommandPalette.Context {
        // Chapters come from the open book; without a reader the selected
        // book is the nearest thing "chapters" could mean.
        let chaptersBook = reader.isOpen ? reader.book : model.selectedBook
        return CommandPalette.Context(
            books: model.orderedBooks,
            chaptersBook: chaptersBook,
            hasSelectedBook: model.selectedBookID != nil,
            readerOpen: reader.isOpen,
            justify: reader.preferences.justify,
            ornaments: reader.preferences.ornaments)
    }

    private var sections: [(group: CommandPalette.Group, items: [Item])] {
        CommandPalette.sections(for: query, in: CommandPalette.items(for: context))
    }

    /// The flat result list the selection index walks, in display order.
    private var flatItems: [Item] {
        sections.flatMap(\.items)
    }

    // MARK: Field

    private var fieldRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.forward.circle")
                .foregroundStyle(.secondary)
            TextField("Go to book, chapter, or command…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .accessibilityLabel("Go to")
                .onChange(of: query) { selection = 0 }
            Text("esc")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
        }
        .padding(12)
    }

    private func moveSelection(_ delta: Int) {
        let count = flatItems.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
        keyboardScrollTarget = selection
    }

    // MARK: Content

    /// Groups items into sections carrying the flat (selection-space)
    /// index each row answers to.
    private var sectionedRows: [(group: CommandPalette.Group, rows: [(index: Int, item: Item)])] {
        var index = 0
        return sections.map { section in
            let rows = section.items.map { item -> (Int, Item) in
                defer { index += 1 }
                return (index, item)
            }
            return (section.group, rows)
        }
    }

    @ViewBuilder
    private var content: some View {
        if flatItems.isEmpty {
            VStack(spacing: 6) {
                Text("No matches for “\(query)”")
                    .font(.callout)
                Text("Try a book title, chapter, or command name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .padding(.horizontal, 20)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sectionedRows, id: \.group) { section in
                            sectionHeader(section.group)
                            ForEach(section.rows, id: \.index) { row in
                                resultRow(row.item, index: row.index)
                                    .id(row.index)
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
                .onChange(of: keyboardScrollTarget) {
                    guard let target = keyboardScrollTarget else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ group: CommandPalette.Group) -> some View {
        Text(group.title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resultRow(_ item: Item, index: Int) -> some View {
        let isSelected = selection == index
        return Button {
            run(item)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.callout)
                        .lineLimit(1)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { selection = index }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            item.subtitle.isEmpty ? item.title : "\(item.title), \(item.subtitle)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Actions

    private func run(_ item: Item?) {
        guard let item else { return }
        model.requestPaletteDismissal()
        switch item.action {
        case .openBook(let id):
            Task { await model.openBookResuming(id: id) }
        case .openChapter(let bookId, let chapterKey, let fragment):
            Task {
                await model.openPassage(
                    bookId: bookId, chapterKey: chapterKey, cfi: nil, fragment: fragment)
            }
        case .run(let command):
            runCommand(command)
        }
    }

    private func runCommand(_ command: CommandPalette.Command) {
        switch command {
        case .importBook:
            Task { await ImportPanel.run(model: model) }
        case .toggleSidebar:
            guard let sidebarVisibility else { return }
            sidebarVisibility.wrappedValue =
                sidebarVisibility.wrappedValue == .detailOnly ? .all : .detailOnly
        case .notesPage:
            guard let id = model.selectedBookID else { return }
            Task {
                if reader.isOpen { reader.close() }
                await model.loadCompiledNotes(bookId: id)
            }
        case .bookmarks:
            model.requestBookmarks()
        case .searchNotes:
            model.requestSearch()
        case .keyboardShortcuts:
            model.requestHelp()
        case .settings:
            openSettings()
        case .paperLight:
            reader.preferences.theme = .light
        case .paperSepia:
            reader.preferences.theme = .sepia
        case .paperDark:
            reader.preferences.theme = .dark
        case .paperNight:
            reader.preferences.theme = .night
        case .paperMatchSystem:
            reader.preferences.followsSystem = true
        case .toggleJustify:
            reader.preferences.justify.toggle()
        case .toggleOrnaments:
            reader.preferences.ornaments.toggle()
        case .indicatorPages:
            reader.preferences.pageIndicator = .pages
        case .indicatorTimeLeft:
            reader.preferences.pageIndicator = .timeLeft
        case .indicatorNone:
            reader.preferences.pageIndicator = .none
        }
    }
}

private extension CommandPalette.Group {
    var title: String {
        switch self {
        case .books: "Books"
        case .chapters: "Chapters"
        case .commands: "Commands"
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
