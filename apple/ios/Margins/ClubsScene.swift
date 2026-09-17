import SwiftUI
import MarginsCore
import MarginsModel

/// The Clubs tab: the reader's private book clubs, one book each. Content is
/// a plain system list; controls float on the toolbar, per the iOS 26
/// content-under-glass model.
struct ClubsScene: View {
    @Environment(ClubModel.self) private var clubs
    @Environment(LibraryModel.self) private var library

    @State private var path: [String] = []
    @State private var nameOpen = false
    @State private var displayName = ""

    var body: some View {
        @Bindable var clubs = clubs
        NavigationStack(path: $path) {
            content
                .navigationTitle("Clubs")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                clubs.createSheetPresented = true
                            } label: {
                                Label("New Book Club", systemImage: "plus")
                            }
                            Button {
                                clubs.joinSheetPresented = true
                            } label: {
                                Label("Join with Code", systemImage: "person.badge.key")
                            }
                            .disabled(!clubs.supportsSharing)
                            Button {
                                displayName = clubs.identity.displayName ?? ""
                                nameOpen = true
                            } label: {
                                Label("My Name…", systemImage: "person")
                            }
                        } label: {
                            Label("Add Club", systemImage: "plus")
                        }
                    }
                }
                .refreshable { await clubs.refresh() }
                .navigationDestination(for: String.self) { clubId in
                    ClubDetailView(clubId: clubId)
                }
                .sheet(isPresented: $clubs.createSheetPresented) {
                    CreateClubSheet()
                        .environment(library)
                }
                .sheet(isPresented: $clubs.joinSheetPresented) {
                    JoinClubSheet()
                }
                .alert("Name", isPresented: $nameOpen) {
                    TextField("Name", text: $displayName)
                    Button("Save") {
                        Task { await clubs.setDisplayName(displayName) }
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .alert(
                    "Book Clubs",
                    isPresented: Binding(
                        get: { clubs.errorMessage != nil },
                        set: { if !$0 { clubs.errorMessage = nil } }
                    )
                ) {
                    Button("OK") {}
                } message: {
                    Text(clubs.errorMessage ?? "")
                }
                #if DEBUG
                .task { await runDebugSeams() }
                #endif
        }
    }

    @ViewBuilder
    private var content: some View {
        if clubs.clubs.isEmpty {
            ContentUnavailableView {
                Label("No book clubs", systemImage: "person.2")
            } description: {
                Text("Start a private club for one book and share the invite code with up to a few friends.")
            } actions: {
                Button("New Book Club") { clubs.createSheetPresented = true }
                    .buttonStyle(.borderedProminent)
                if clubs.supportsSharing {
                    Button("Join with a Code") { clubs.joinSheetPresented = true }
                } else {
                    Label("Sharing needs iCloud", systemImage: "icloud.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            List {
                ForEach(clubs.clubs) { club in
                    NavigationLink(value: club.id) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(club.name)
                                .font(.headline)
                            Text("\(club.bookTitle) — \(club.bookAuthor)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(
                                club.members.count == 1
                                    ? "1 member" : "\(club.members.count) members"
                            )
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            Text(club.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    #if DEBUG
    /// With `MARGINS_CLUB_FIXTURE` set, `LibraryScene` creates the club;
    /// this seam then opens its detail so the merged view can be captured
    /// without touch synthesis.
    private func runDebugSeams() async {
        guard ProcessInfo.processInfo.environment["MARGINS_CLUB_FIXTURE"] != nil else { return }
        for _ in 0..<50 where clubs.clubs.isEmpty {
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard path.isEmpty, let first = clubs.clubs.first else { return }
        path = [first.id]
    }
    #endif
}
