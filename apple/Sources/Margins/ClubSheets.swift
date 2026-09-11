import AppKit
import MarginsCore
import MarginsModel
import SwiftUI

/// New-club sheet: name the club, pick the one book it reads, and set the
/// name other members will see.
struct CreateClubSheet: View {
    @Environment(ClubModel.self) private var clubs
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var displayName = ""
    @State private var selectedBookID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Book Club")
                .font(.title2.weight(.semibold))
            Text("A club reads one book. Everyone imports the same EPUB.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                TextField("Club Name", text: $name)
                TextField("Your Name", text: $displayName)
                Picker("Book", selection: $selectedBookID) {
                    Text("Choose a book…").tag(String?.none)
                    ForEach(library.books) { book in
                        Text("\(book.title) — \(book.author)")
                            .tag(String?.some(book.id))
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if !clubs.supportsSharing {
                    Label("Sharing needs iCloud; the club stays on this Mac.", systemImage: "icloud.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            selectedBookID = library.selectedBookID ?? library.books.first?.id
            displayName = clubs.identity.displayName
                ?? Host.current().localizedName
                ?? ""
        }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedBookID != nil
    }

    private func create() {
        guard let bookID = selectedBookID else { return }
        let clubName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let memberName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if await clubs.createClub(
                bookId: bookID, name: clubName, displayName: memberName
            ) != nil {
                dismiss()
            }
        }
    }
}

/// Join sheet: the four-character code is the whole flow.
struct JoinClubSheet: View {
    @Environment(ClubModel.self) private var clubs
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var displayName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Join a Book Club")
                .font(.title2.weight(.semibold))
            Text("Enter the four-character code the club's admin shared with you.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                TextField("Invite Code", text: $code)
                    .font(.system(.title3, design: .monospaced))
                TextField("Your Name", text: $displayName)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Join") { join() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canJoin)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            displayName = clubs.identity.displayName
                ?? Host.current().localizedName
                ?? ""
        }
    }

    private var canJoin: Bool {
        ClubCode.isValid(code)
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func join() {
        let memberName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if await clubs.joinClub(code: code, displayName: memberName) != nil {
                dismiss()
            }
        }
    }
}
