import SwiftUI
import MarginsCore
import MarginsModel

/// One club on iOS: identity, roster, invite code, and the merged document.
/// System list content; actions live in rows and on the toolbar.
struct ClubDetailView: View {
    let clubId: String

    @Environment(ClubModel.self) private var clubs
    @Environment(\.dismiss) private var dismiss

    @State private var exportURL: URL?
    @State private var showingDeleteConfirmation = false
    @State private var showingLeaveConfirmation = false
    @State private var memberPendingRemoval: ClubMember?
    @State private var memberPendingPromote: ClubMember?
    @State private var renameOpen = false
    @State private var renameText = ""

    var body: some View {
        clubContent
            .navigationTitle(clubs.selectedClub?.name ?? "Club")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { clubToolbar }
            .sheet(
                isPresented: Binding(
                    get: { exportURL != nil },
                    set: { if !$0 { exportURL = nil } }
                )
            ) {
                if let exportURL {
                    ExportSheet(url: exportURL)
                }
            }
            .modifier(ClubDetailDialogs(
                clubs: clubs,
                dismiss: dismiss,
                showingDeleteConfirmation: $showingDeleteConfirmation,
                showingLeaveConfirmation: $showingLeaveConfirmation,
                memberPendingRemoval: $memberPendingRemoval,
                memberPendingPromote: $memberPendingPromote,
                renameOpen: $renameOpen,
                renameText: $renameText
            ))
    }

    @ViewBuilder
    private var clubContent: some View {
        if let club = clubs.selectedClub, club.id == clubId {
            List {
                Section { header(club) }
                membersSection(club)
                notesSections
            }
            .listStyle(.insetGrouped)
            .refreshable { await clubs.loadNotes() }
        } else if clubs.clubs.contains(where: { $0.id == clubId }) {
            ProgressView()
                .task { await clubs.selectClub(id: clubId) }
        } else {
            ProgressView()
                .task { dismiss() }
        }
    }

    @ToolbarContentBuilder
    private var clubToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    Task { await clubs.publishOwnSnapshot() }
                } label: {
                    Label("Sync My Notes", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(clubs.isBusy)
                Button {
                    Task { await export() }
                } label: {
                    Label("Export Markdown", systemImage: "square.and.arrow.up")
                }
                .disabled(clubs.notes?.chapters.isEmpty ?? true)
                if clubs.isAdmin(of: clubs.selectedClub) {
                    Button("Rename") {
                        renameText = clubs.selectedClub?.name ?? ""
                        renameOpen = true
                    }
                }
                Divider()
                if clubs.isOwner(of: clubs.selectedClub) {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete Club", systemImage: "trash")
                    }
                    .disabled(clubs.isBusy)
                } else if clubs.selectedClub != nil {
                    Button(role: .destructive) {
                        showingLeaveConfirmation = true
                    } label: {
                        Label("Leave Club", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(clubs.isBusy)
                }
            } label: {
                Label("Club Actions", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: Header

    private func header(_ club: Club) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(club.name)
                    .font(.title2.weight(.semibold))
                Text("\(club.bookTitle) — \(club.bookAuthor)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(club.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 12) {
                Toggle(
                    "Spoiler protection",
                    isOn: Binding(
                        get: { clubs.spoilerProtection },
                        set: { value in Task { await clubs.setSpoilerProtection(value) } }
                    )
                )
                .font(.subheadline)
            }
            if clubs.supportsSharing, let code = clubs.selectedClub?.inviteCode {
                HStack(spacing: 8) {
                    Text("Invite code")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(code)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                    Spacer()
                    ShareLink(item: code) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                    }
                    if clubs.isAdmin(of: club) {
                        Button {
                            Task { await clubs.rotateInviteCode() }
                        } label: {
                            Label("New Code", systemImage: "arrow.clockwise")
                                .labelStyle(.iconOnly)
                        }
                    }
                }
            } else if !clubs.supportsSharing {
                Label("This iPhone only — sign in to iCloud to invite readers.", systemImage: "icloud.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func membersSection(_ club: Club) -> some View {
        Section("Members") {
            ForEach(club.roster) { member in
                memberRow(club, member)
            }
        }
    }

    private func memberRow(_ club: Club, _ member: ClubMember) -> some View {
        HStack {
            Text(member.displayName)
            if member.isAdmin {
                Image(systemName: "crown.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if clubs.isCurrentMember(member) {
                Text("You")
                    .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            memberSwipeActions(club, member)
        }
    }

    @ViewBuilder
    private func memberSwipeActions(_ club: Club, _ member: ClubMember) -> some View {
        if clubs.isAdmin(of: club), !clubs.isCurrentMember(member) {
            Button {
                memberPendingPromote = member
            } label: {
                Label("Make Admin", systemImage: "crown")
            }
            if clubs.supportsSharing {
                Button(role: .destructive) {
                    memberPendingRemoval = member
                } label: {
                    Label("Remove", systemImage: "person.badge.minus")
                }
            }
        }
    }

    // MARK: Merged document

    @ViewBuilder
    private var notesSections: some View {
        if let notes = clubs.notes {
            if notes.chapters.isEmpty {
                Section {
                    Text("No club notes yet. Write notes while reading, then Sync My Notes.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(notes.chapters) { chapter in
                    Section {
                        if chapter.othersHidden {
                            Label(hiddenText(chapter), systemImage: "eye.slash")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(chapter.passages) { passage in
                            passageRow(passage)
                        }
                        ForEach(chapter.contributions) { contribution in
                            contributionRow(contribution)
                        }
                    } header: {
                        Text("\(chapter.chapterIndex + 1). \(chapter.chapterTitle)")
                    }
                }
            }
        }
    }

    private func passageRow(_ passage: ClubPassage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !passage.quote.isEmpty {
                Text(passage.quote)
                    .font(.callout.italic())
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.6))
                            .frame(width: 3)
                    }
            }
            ForEach(passage.marks) { entry in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(entry.displayName):")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(entry.isSelf ? Color.accentColor : .secondary)
                    Text(entry.mark.body.isEmpty ? "highlight" : entry.mark.body)
                        .foregroundStyle(entry.mark.body.isEmpty ? .secondary : .primary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func contributionRow(_ contribution: ClubContribution) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(contribution.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(contribution.isSelf ? Color.accentColor : .secondary)
            Text(contribution.body)
        }
        .padding(.vertical, 2)
    }

    private func hiddenText(_ chapter: ClubChapter) -> String {
        let who = chapter.hiddenMemberCount == 1
            ? "1 other member's" : "\(chapter.hiddenMemberCount) other members'"
        return "\(who) notes are hidden until you finish this chapter."
    }

    private func export() async {
        guard let payload = await clubs.exportMarkdown() else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(payload.filename)
        do {
            try payload.markdown.write(to: url, atomically: true, encoding: .utf8)
            exportURL = url
        } catch {
            clubs.errorMessage = String(describing: error)
        }
    }
}

/// Delete / leave / remove / promote / rename / error chrome for one club.
private struct ClubDetailDialogs: ViewModifier {
    var clubs: ClubModel
    var dismiss: DismissAction
    @Binding var showingDeleteConfirmation: Bool
    @Binding var showingLeaveConfirmation: Bool
    @Binding var memberPendingRemoval: ClubMember?
    @Binding var memberPendingPromote: ClubMember?
    @Binding var renameOpen: Bool
    @Binding var renameText: String

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Delete \"\(clubs.selectedClub?.name ?? "Club")\"?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Club", role: .destructive) {
                    Task {
                        if await clubs.deleteSelectedClub() {
                            dismiss()
                        }
                    }
                }
            } message: {
                Text("This removes the club and its local snapshots. Your notes are not touched.")
            }
            .confirmationDialog(
                "Leave \"\(clubs.selectedClub?.name ?? "Club")\"?",
                isPresented: $showingLeaveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Leave Club", role: .destructive) {
                    Task {
                        if await clubs.leaveSelectedClub() {
                            dismiss()
                        }
                    }
                }
            } message: {
                Text("You lose access to the club's shared notes. Your own notes are not touched.")
            }
            .confirmationDialog(
                "Remove Member?",
                isPresented: Binding(
                    get: { memberPendingRemoval != nil },
                    set: { if !$0 { memberPendingRemoval = nil } }
                ),
                titleVisibility: .visible,
                presenting: memberPendingRemoval
            ) { member in
                Button("Remove \(member.displayName)", role: .destructive) {
                    Task { await clubs.removeMember(id: member.id) }
                }
            } message: { _ in
                Text("They are removed from the roster and their shared snapshot is deleted.")
            }
            .confirmationDialog(
                "Promote Member?",
                isPresented: Binding(
                    get: { memberPendingPromote != nil },
                    set: { if !$0 { memberPendingPromote = nil } }
                ),
                titleVisibility: .visible,
                presenting: memberPendingPromote
            ) { member in
                Button("Promote \(member.displayName)") {
                    Task { await clubs.promoteMember(id: member.id) }
                }
            } message: { member in
                Text(
                    "Promote \(member.displayName) to admin? They can rename the club, remove members, and rotate the invite code. You become a member.\n\nIf you created the club, you can still delete it."
                )
            }
            .alert("Name", isPresented: $renameOpen) {
                TextField("Club Name", text: $renameText)
                Button("Save") {
                    Task { await clubs.renameSelectedClub(renameText) }
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
    }
}

/// The share sheet for an exported markdown file.
private struct ExportSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "doc.text")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text(url.lastPathComponent)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                ShareLink(item: url) {
                    Label("Share Markdown", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .navigationTitle("Export Club Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
