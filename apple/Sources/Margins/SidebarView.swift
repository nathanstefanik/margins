import SwiftUI
import MarginsCore
import MarginsModel

struct SidebarView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ClubModel.self) private var clubs
    @State private var showingRemovalDialog = false
    @State private var bookPendingRemoval: BookSummary?

    var body: some View {
        @Bindable var model = model
        @Bindable var clubs = clubs
        VStack(spacing: 0) {
            List(selection: $model.selectedBookID) {
                ForEach(model.books) { book in
                    BookRowView(book: book)
                        .tag(book.id)
                        .simultaneousGesture(TapGesture().onEnded {
                            Task { await clubs.selectClub(id: nil) }
                        })
                        .onTapGesture(count: 2) {
                            Task { await model.openBookResuming(id: book.id) }
                        }
                        .contextMenu {
                            Button("Remove…", role: .destructive) {
                                requestRemoval(of: book)
                            }
                        }
                }
            }
            .listStyle(.sidebar)
            if let status = model.importStatus {
                Divider()
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            clubSection(selection: $clubs.selectedClubID)
            Divider()
            libraryRootBar
        }
        .navigationTitle("Library")
        .confirmationDialog(
            "Remove Book?",
            isPresented: $showingRemovalDialog,
            titleVisibility: .visible,
            presenting: bookPendingRemoval
        ) { book in
            Button("Remove", role: .destructive) {
                removeBook(book)
            }
        } message: { book in
            Text("Remove \"\(book.title)\" and its notes from the library? The original EPUB file on disk is not touched.")
        }
        .onChange(of: model.selectedBookID) {
            Task { await model.loadSelectedBook() }
        }
        .onChange(of: clubs.selectedClubID) {
            if clubs.selectedClubID != nil {
                model.selectedBookID = nil
            }
        }
    }

    /// Book clubs live under the library list, with their own selection:
    /// selecting a club clears the book selection and vice versa, so the
    /// detail area always has one unambiguous subject.
    @ViewBuilder
    private func clubSection(selection: Binding<String?>) -> some View {
        Divider()
        HStack(spacing: 6) {
            Text("Book Clubs")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("New Book Club…") {
                    clubs.createSheetPresented = true
                }
                Button("Join Book Club…") {
                    clubs.joinSheetPresented = true
                }
                .disabled(!clubs.supportsSharing)
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Add Book Club")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)

        if clubs.clubs.isEmpty {
            Text("Create or join a club to read together.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
        } else {
            List(selection: selection) {
                ForEach(clubs.clubs) { club in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(club.name)
                            .lineLimit(1)
                        Text(club.bookTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .tag(club.id)
                }
            }
            .listStyle(.sidebar)
            .frame(height: min(CGFloat(clubs.clubs.count) * 48 + 8, 190))
        }
    }

    /// Pinned under the list, outside the scroll content: the library root
    /// and the directory picker. Replaces the old floating overlay that sat
    /// on top of the last row.
    private var libraryRootBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(model.libraryRoot)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.libraryRoot)
            Spacer(minLength: 0)
            Button {
                Task { await RootPanel.run(model: model) }
            } label: {
                Image(systemName: "folder.badge.ellipsis")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Choose Library Directory…")
            .help("Choose Library Directory…")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func requestRemoval(of book: BookSummary) {
        bookPendingRemoval = book
        showingRemovalDialog = true
    }

    private func removeBook(_ book: BookSummary) {
        Task { await model.removeBook(id: book.id) }
    }
}
