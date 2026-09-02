import SwiftUI
import MarginsCore
import MarginsModel

/// Non-modal Spotlight-style command palette inside the main window. The
/// field keeps keyboard focus for the whole lifetime: ↑/↓ (or ⌃N/⌃P) move a
/// virtual selection that wraps, Enter opens it, hover moves the selection
/// without stealing focus, and Esc (via the shell key monitor) dismisses.
/// Dismissal also: clicking anywhere outside the panel, or opening a hit.
struct SearchOverlay: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ReaderModel.self) private var reader
    @FocusState private var fieldFocused: Bool
    // The query lifecycle (debounce, latest-wins, cap) lives in the model.
    private var controller: SearchController { model.search }

    var body: some View {
        ZStack {
            // Click-away scrim: a click anywhere outside the panel closes.
            Color.clear
                .contentShape(.rect)
                .onTapGesture { model.requestSearchDismissal() }

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
            fieldFocused = true
        }
        .onDisappear {
            fieldFocused = false
            controller.reset()
        }
        .onExitCommand {
            model.requestSearchDismissal()
        }
    }

    // MARK: Field

    private var fieldRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search notes…", text: Binding(
                get: { controller.query },
                set: { controller.setQuery($0) }
            ))
            .textFieldStyle(.plain)
            .font(.title3)
            .focused($fieldFocused)
            .accessibilityLabel("Search notes")
            .onSubmit { submit() }
            .onKeyPress(.upArrow) {
                controller.moveSelection(-1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                controller.moveSelection(1)
                return .handled
            }
            .onKeyPress { press in
                // Vim hands: ⌃N/⌃P move the selection like ↓/↑.
                guard press.modifiers == .control else { return .ignored }
                switch press.key {
                case "n": controller.moveSelection(1)
                    return .handled
                case "p": controller.moveSelection(-1)
                    return .handled
                default: return .ignored
                }
            }
            if controller.isSearching {
                ProgressView()
                    .controlSize(.small)
            }
            Text("esc")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
        }
        .padding(12)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if controller.isQueryEmpty {
            recents
        } else if controller.results.isEmpty {
            noMatches
        } else {
            resultRows
        }
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 0) {
            if controller.recents.isEmpty {
                hint("Type to search chapter notes, chapter titles, and books.")
            } else {
                sectionHeader("Recent Searches")
                ForEach(Array(controller.recents.enumerated()), id: \.offset) { index, recent in
                    Button {
                        controller.runRecent(recent)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            Text(recent)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(rowBackground(selected: controller.selection == index))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering { controller.select(index: index) }
                    }
                }
                Divider().padding(.vertical, 6)
                hint("Type to search chapter notes, chapter titles, and books.")
            }
        }
    }

    private var noMatches: some View {
        VStack(spacing: 6) {
            Text("No matches for “\(controller.query)”")
                .font(.callout)
            Text("Search looks at note bodies, chapter titles, and book titles or authors.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
    }

    // MARK: Result rows

    private struct PaletteRow: Identifiable {
        let index: Int
        let hit: NoteSearchHit
        var id: Int { index }
    }

    /// Groups hits into sections with global (selection-space) row indices.
    private var sectionedRows: [(title: String, rows: [PaletteRow])] {
        var result: [(String, [PaletteRow])] = []
        var index = 0
        for section in SearchResultsOrganizer.sections(for: controller.results) {
            let rows = section.hits.map { hit -> PaletteRow in
                defer { index += 1 }
                return PaletteRow(index: index, hit: hit)
            }
            result.append((section.title, rows))
        }
        return result
    }

    private var resultRows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sectionedRows, id: \.title) { section in
                        sectionHeader(section.title)
                        ForEach(section.rows) { row in
                            resultRow(row)
                        }
                    }
                    if controller.isTruncated {
                        Text("\(controller.totalResults - controller.results.count) more matches…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: 360)
            .onChange(of: controller.selection) {
                guard let selected = controller.selection else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(selected, anchor: .center)
                }
            }
        }
    }

    private func resultRow(_ row: PaletteRow) -> some View {
        let isSelected = controller.selection == row.index
        return Button {
            open(row.hit)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                breadcrumb(row.hit)
                mainLine(row.hit)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(selected: isSelected))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .id(row.index)
        .onHover { hovering in
            // Hover moves the selection but never steals field focus.
            if hovering { controller.select(index: row.index) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(row.hit))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func breadcrumb(_ hit: NoteSearchHit) -> some View {
        HStack(spacing: 4) {
            Text(hit.bookTitle)
            if hit.chapterTitle.isEmpty {
                Text("Book")
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                Text(hit.chapterTitle)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private func mainLine(_ hit: NoteSearchHit) -> some View {
        switch hit.kind {
        case .noteContent:
            Text(SearchHighlighter.attributed(
                hit.snippet,
                ranges: hit.snippetRanges,
                highlight: highlightAttributes
            ))
            .font(.callout)
            .lineLimit(1)
        case .chapterTitle:
            Text(SearchHighlighter.attributed(
                hit.chapterTitle,
                ranges: hit.titleRanges,
                highlight: highlightAttributes
            ))
            .font(.callout)
            .lineLimit(1)
        case .bookTarget:
            Text(SearchHighlighter.attributed(
                hit.bookTitle,
                ranges: hit.titleRanges,
                highlight: highlightAttributes
            ))
            .font(.callout)
            .lineLimit(1)
        }
    }

    /// Matched text: bold and accent-tinted, straight from the core ranges.
    private var highlightAttributes: AttributeContainer {
        var container = SearchHighlighter.highlightIntent
        container.foregroundColor = .accentColor
        return container
    }

    private func rowBackground(selected: Bool) -> Color {
        selected ? Color.accentColor.opacity(0.18) : .clear
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
    }

    private func accessibilityText(_ hit: NoteSearchHit) -> String {
        switch hit.kind {
        case .noteContent:
            "\(hit.bookTitle), chapter \(hit.chapterTitle): \(hit.snippet)"
        case .chapterTitle:
            "Chapter \(hit.chapterTitle) in \(hit.bookTitle)"
        case .bookTarget:
            "Book \(hit.bookTitle) by \(hit.bookAuthor)"
        }
    }

    // MARK: Actions

    private func submit() {
        if controller.isQueryEmpty {
            if let recent = controller.selectedRecent ?? controller.recents.first {
                controller.runRecent(recent)
            }
            return
        }
        guard let hit = controller.selectedHit ?? controller.orderedResults.first else { return }
        open(hit)
    }

    private func open(_ hit: NoteSearchHit) {
        controller.commitRecent(controller.query)
        Task {
            guard let book = await model.getBook(id: hit.bookId) else { return }
            let chapter: ChapterMeta?
            if hit.chapterKey.isEmpty {
                // Book-level target: land on its first chapter.
                chapter = book.chapters.first
            } else {
                chapter = book.chapters.first(where: { $0.key == hit.chapterKey })
            }
            guard let chapter else { return }
            reader.open(book: book, chapter: chapter)
            model.requestSearchDismissal()
        }
    }
}
