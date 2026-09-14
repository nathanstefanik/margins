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
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Book Club")
                .font(.title2.weight(.semibold))
            Text("A club reads one book. Everyone imports the same EPUB.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                TextField("Club Name", text: $name)
                TextField("Name", text: $displayName)
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
        .disabled(isSubmitting || clubs.isBusy)
        .onAppear {
            selectedBookID = library.selectedBookID ?? library.books.first?.id
        }
    }

    private var canCreate: Bool {
        !isSubmitting
            && !clubs.isBusy
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedBookID != nil
    }

    private func create() {
        guard canCreate, let bookID = selectedBookID else { return }
        isSubmitting = true
        let clubName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let memberName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if await clubs.createClub(
                bookId: bookID, name: clubName, displayName: memberName
            ) != nil {
                dismiss()
            } else {
                isSubmitting = false
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
    @State private var isSubmitting = false

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
                TextField("Name", text: $displayName)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting || clubs.isBusy)
                Button("Join") { join() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canJoin)
            }
        }
        .padding(20)
        .frame(width: 420)
        .disabled(isSubmitting || clubs.isBusy)
    }

    private var canJoin: Bool {
        !isSubmitting
            && !clubs.isBusy
            && ClubCode.isValid(code)
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func join() {
        guard canJoin else { return }
        isSubmitting = true
        let memberName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if await clubs.joinClub(code: code, displayName: memberName) != nil {
                dismiss()
            } else {
                isSubmitting = false
            }
        }
    }
}
