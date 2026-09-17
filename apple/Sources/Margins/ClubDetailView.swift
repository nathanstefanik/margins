import AppKit
import MarginsCore
import MarginsModel
import SwiftUI

/// The selected club: identity, roster, invite controls, and the merged
/// document — every member's marks clustered under one quote, long-form
/// notes under names, and spoiler placeholders instead of hidden content.
struct ClubDetailView: View {
    @Environment(ClubModel.self) private var clubs

    @State private var showingDeleteConfirmation = false
    @State private var showingLeaveConfirmation = false
    @State private var memberPendingRemoval: ClubMember?
    @State private var memberPendingPromote: ClubMember?
    @State private var renameOpen = false
    @State private var renameText = ""

    var body: some View {
        if let club = clubs.selectedClub {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(club)
                    Divider()
                    content
                }
                .padding(24)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .confirmationDialog(
                "Delete \"\(club.name)\"?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Club", role: .destructive) {
                    Task { await clubs.deleteSelectedClub() }
                }
            } message: {
                Text("This removes the club and its local snapshots. Notes in your library are not touched.")
            }
            .confirmationDialog(
                "Leave \"\(club.name)\"?",
                isPresented: $showingLeaveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Leave Club", role: .destructive) {
                    Task { await clubs.leaveSelectedClub() }
                }
            } message: {
                Text("You lose access to the club's shared notes. Notes in your library are not touched.")
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
            } message: { member in
                Text("\(member.displayName) is removed from the roster and their shared snapshot is deleted.")
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
        }
    }

    // MARK: Header

    private func header(_ club: Club) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(club.name)
                        .font(.system(.largeTitle, design: .serif).weight(.semibold))
                    if clubs.isAdmin(of: club) {
                        Button {
                            renameText = club.name
                            renameOpen = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Rename club")
                    }
                }
                Text("\(club.bookTitle) — \(club.bookAuthor)")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(club.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 10) {
                Label(
                    "\(club.members.count) member\(club.members.count == 1 ? "" : "s")",
                    systemImage: "person.2"
                )
                if clubs.supportsSharing {
                    if clubs.isAdmin(of: club) {
                        inviteControls(club)
                    } else {
                        Text("Invite code: \(club.inviteCode)")
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } else {
                    Label("This Mac only", systemImage: "icloud.slash")
                        .help("Sign in to iCloud to invite other readers.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            roster(club)

            HStack(spacing: 10) {
                Button {
                    Task { await clubs.publishOwnSnapshot() }
                } label: {
                    Label("Sync My Notes", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(clubs.isBusy)
                .help("Rebuild your snapshot from this device's notes and share it.")

                Button {
                    Task { await ClubExportPanel.run(model: clubs) }
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .disabled(clubs.notes?.chapters.isEmpty ?? true)

                Button {
                    Task { await ClubExportPanel.copy(model: clubs) }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(clubs.notes?.chapters.isEmpty ?? true)

                Toggle(
                    "Spoiler protection",
                    isOn: Binding(
                        get: { clubs.spoilerProtection },
                        set: { value in Task { await clubs.setSpoilerProtection(value) } }
                    )
                )
                .toggleStyle(.switch)
                .help("Hide other members' notes for the chapter you are reading and later ones.")

                Spacer()

                if clubs.isOwner(of: club) {
                    Button("Delete Club", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                    .disabled(clubs.isBusy)
                } else {
                    Button("Leave Club", role: .destructive) {
                        showingLeaveConfirmation = true
                    }
                    .disabled(clubs.isBusy)
                }
            }
            .controlSize(.regular)
        }
    }

    private func inviteControls(_ club: Club) -> some View {
        HStack(spacing: 6) {
            Text("Invite code")
            Text(club.inviteCode)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(club.inviteCode, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy the invite code")
            Button {
                Task { await clubs.rotateInviteCode() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Rotate the invite code; the old code stops working.")
        }
    }

    private func roster(_ club: Club) -> some View {
        HStack(spacing: 6) {
            ForEach(club.roster) { member in
                HStack(spacing: 4) {
                    Text(member.displayName)
                    if member.isAdmin {
                        Image(systemName: "crown.fill")
                            .font(.caption2)
                            .help("Admin")
                    }
                    if clubs.isAdmin(of: club), !clubs.isCurrentMember(member) {
                        Button {
                            memberPendingPromote = member
                        } label: {
                            Image(systemName: "crown")
                        }
                        .buttonStyle(.borderless)
                        .help("Promote \(member.displayName)")
                        if clubs.supportsSharing {
                            Button {
                                memberPendingRemoval = member
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove \(member.displayName)")
                        }
                    }
                }
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: Capsule())
            }
        }
    }

    // MARK: Merged document

    @ViewBuilder
    private var content: some View {
        if let notes = clubs.notes {
            if notes.chapters.isEmpty {
                ContentUnavailableView {
                    Label("No club notes yet", systemImage: "person.2")
                } description: {
                    Text("Write notes while reading, then choose Sync My Notes.")
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                ForEach(notes.chapters) { chapter in
                    chapterSection(chapter)
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        }
    }

    private func chapterSection(_ chapter: ClubChapter) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(chapter.chapterIndex + 1). \(chapter.chapterTitle)")
                .font(.system(.title3, design: .serif).weight(.semibold))

            if chapter.othersHidden {
                Label(hiddenText(chapter), systemImage: "eye.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(chapter.passages) { passage in
                passageView(passage)
            }

            ForEach(chapter.contributions) { contribution in
                VStack(alignment: .leading, spacing: 4) {
                    Text(contribution.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(
                            contribution.isSelf ? Color.accentColor : .secondary
                        )
                    Text(contribution.body)
                        .textSelection(.enabled)
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.tertiary)
                        .frame(width: 2)
                }
            }
        }
    }

    private func passageView(_ passage: ClubPassage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !passage.quote.isEmpty {
                Text(passage.quote)
                    .font(.system(.body, design: .serif))
                    .italic()
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
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func hiddenText(_ chapter: ClubChapter) -> String {
        let who = chapter.hiddenMemberCount == 1
            ? "1 other member's" : "\(chapter.hiddenMemberCount) other members'"
        return "\(who) notes are hidden until you finish this chapter."
    }
}
