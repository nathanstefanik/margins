import SwiftUI
import MarginsCore
import MarginsModel

/// The Clubs tab: the reader's private book clubs, one book each. Content is
/// a plain system list; controls float on the toolbar, per the iOS 26
/// content-under-glass model.
struct ClubsScene: View {
    @Environment(ClubModel.self) private var clubs
    @Environment(LibraryModel.self) private var library

    @State private var showingCreate = false
    @State private var showingJoin = false
    @State private var path: [String] = []

    var body: some View {
        @Bindable var clubs = clubs
        NavigationStack(path: $path) {
            content
                .navigationTitle("Clubs")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                showingCreate = true
                            } label: {
                                Label("New Book Club", systemImage: "plus")
                            }
                            Button {
                                showingJoin = true
                            } label: {
                                Label("Join with Code", systemImage: "person.badge.key")
                            }
                            .disabled(!clubs.supportsSharing)
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
                Button("New Book Club") { showingCreate = true }
                    .buttonStyle(.borderedProminent)
                if clubs.supportsSharing {
                    Button("Join with a Code") { showingJoin = true }
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
