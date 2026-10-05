import MarginsCore
import MarginsModel
import SwiftUI

struct SidebarView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ClubModel.self) private var clubs
    @State private var showingRemovalDialog = false
    @State private var bookPendingRemoval: BookSummary?

    /// One List, one selection: books and clubs share the sidebar, so the
    /// row identity carries which kind it is and the setter maps it back
    /// onto `selectedBookID` / `selectedClubID`. The onChange handlers
    /// below keep the two selections mutually exclusive and drive the
    /// detail-area loads, exactly as the split lists did.
    private enum SidebarSelection: Hashable {
        case book(String)
        case club(String)
    }

    private var selection: Binding<SidebarSelection?> {
        Binding(
            get: {
                if let id = model.selectedBookID { return .book(id) }
                if let id = clubs.selectedClubID { return .club(id) }
                return nil
            },
            set: { newValue in
                switch newValue {
                case .book(let id):
                    model.selectedBookID = id
                case .club(let id):
                    // The club list wrote selectedClubID directly;
                    // selectClub on the way out loads the club's notes.
                    clubs.selectedClubID = id
                case nil:
                    model.selectedBookID = nil
                    clubs.selectedClubID = nil
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                Section("Library") {
                    ForEach(model.orderedBooks) { book in
                        BookRowView(book: book)
                            .tag(SidebarSelection.book(book.id))
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
                Section {
                    if clubs.clubs.isEmpty {
                        Text("Create or join a club to read together.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(clubs.clubs) { club in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(club.name)
                                    .lineLimit(1)
                                Text(club.bookTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .tag(SidebarSelection.club(club.id))
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("Book Clubs")
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
            Text(
                "Remove \"\(book.title)\" and its notes from the library? The original EPUB file on disk is not touched."
            )
        }
        .onChange(of: model.selectedBookID) {
            // Keyboard moves can pick a book while a club is selected;
            // the detail area must not keep showing the club.
            if model.selectedBookID != nil, clubs.selectedClubID != nil {
                Task { await clubs.selectClub(id: nil) }
            }
            Task { await model.loadSelectedBook() }
        }
        .onChange(of: clubs.selectedClubID) {
            if clubs.selectedClubID != nil {
                model.selectedBookID = nil
            }
            // The club list writes `selectedClubID` directly; populating
            // `selectedClub` and its notes is `selectClub`'s job. Create
            // and join flows already call it, so only load when the
            // selection moved without a matching club loaded.
            if let id = clubs.selectedClubID, clubs.selectedClub?.id != id {
                Task { await clubs.selectClub(id: id) }
            }
        }
    }

    private func requestRemoval(of book: BookSummary) {
        bookPendingRemoval = book
        showingRemovalDialog = true
    }

    private func removeBook(_ book: BookSummary) {
        Task { await model.removeBook(id: book.id) }
    }
}
