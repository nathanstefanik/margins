import AppKit
import MarginsModel
import SwiftUI

struct ReaderView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ReaderModel.self) private var reader
    @State private var typographyOpen = false

    /// Focus-mode footer fade: the text is `footerRevealed` only while the
    /// pointer has moved over the reader in the last few seconds. Opacity
    /// only — the footer band keeps its size so nothing reflows.
    @State private var footerRevealed = true
    @State private var footerFadeTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ReaderWebView(model: model, reader: reader)
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                ReaderFooter(reader: reader)
                    .opacity(footerRevealed || !reader.focusMode ? 1 : 0)
            }
            .background(Paper.background(reader.preferences.theme))
            .frame(maxWidth: .infinity)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    revealFooter()
                case .ended:
                    // The 3s timer armed by the last .active move keeps
                    // running — departure is just another pause.
                    break
                }
            }
            if reader.notesVisible {
                // One hairline between the page column and the notes pane —
                // the pane is part of the same sheet, so no box, just a rule.
                Rectangle()
                    .fill(Paper.secondaryInk(reader.preferences.theme).opacity(0.2))
                    .frame(width: 1)
                // 320 is the editor's usable floor; it may grow on wide
                // windows so long notes do not scroll in a cramped column.
                NotesPane()
                    .frame(minWidth: 320, idealWidth: 340, maxWidth: 460)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.22), value: reader.notesVisible)
        // Focus mode strips the window chrome too — toolbar hides; the
        // notes pane, if open, stays.
        .toolbar(reader.focusMode ? .hidden : .automatic, for: .windowToolbar)
        .onChange(of: reader.focusMode) {
            if !reader.focusMode { revealFooter() }
        }
        .windowToolbarFullScreenVisibilityReader()
        .navigationTitle(reader.book?.title ?? "Reader")
        .task(id: reader.book?.id) {
            await model.loadBookmarks(reader: reader)
        }
        .onChange(of: reader.currentCfi) {
            Task { await model.stampBookmarkPositions(reader: reader) }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                // Distinct from the sidebar toggle, which owns
                // "sidebar.left": this exits the reading view for the
                // library (home).
                Button("Library", systemImage: "house", action: reader.close)
                    .help("Back to library (l)")
            }
            ToolbarItem(placement: .navigation) {
                Button("Notes", systemImage: "square.and.pencil") {
                    reader.toggleNotes()
                }
            }
            ToolbarItem(placement: .navigation) {
                Button {
                    Task {
                        let result = await model.toggleBookmark(reader: reader)
                        if case .choose = result {
                            model.requestBookmarks()
                        }
                    }
                } label: {
                    Label(
                        BookmarkDisplay.toggleTitle(onPageCount: reader.bookmarksOnPage.count),
                        systemImage: reader.pageIsBookmarked ? "bookmark.fill" : "bookmark"
                    )
                }
                .disabled(model.bookmarkToggleInFlight || (reader.currentCfi?.isEmpty ?? true))
                .help("Toggle bookmark (b). Press B for the list.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    typographyOpen.toggle()
                } label: {
                    Label("Typography", systemImage: "textformat")
                }
                .popover(isPresented: $typographyOpen, arrowEdge: .bottom) {
                    TypographyPopover(
                        preferences: reader.preferences,
                        effectivePageCount: reader.effectivePageCount
                    )
                }
            }
        }
    }

    /// Show the footer and restart the idle timer that dims it in focus
    /// mode. Every pointer move over the page re-arms it.
    private func revealFooter() {
        footerFadeTask?.cancel()
        footerRevealed = true
        guard reader.focusMode else { return }
        footerFadeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                footerRevealed = false
            }
        }
    }
}

extension View {
    /// Full-screen windows reveal their toolbar only under the pointer —
    /// applied unconditionally (focus mode or not). No-op before the API.
    @ViewBuilder
    func windowToolbarFullScreenVisibilityReader() -> some View {
        if #available(macOS 15.5, *) {
            self.windowToolbarFullScreenVisibility(.onHover)
        } else {
            self
        }
    }
}
