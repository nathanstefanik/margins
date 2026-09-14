import SwiftUI
import UIKit
import MarginsCore
import MarginsModel

/// New club: name it, pick the one book it reads, set the name others see.
struct CreateClubSheet: View {
    @Environment(ClubModel.self) private var clubs
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var displayName = ""
    @State private var bookID: String?
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Club") {
                    TextField("Club Name", text: $name)
                    TextField("Your Name", text: $displayName)
                }
                Section("Book") {
                    Picker("Book", selection: $bookID) {
                        ForEach(library.books) { book in
                            Text("\(book.title) — \(book.author)")
                                .tag(String?.some(book.id))
                        }
                    }
                }
                if !clubs.supportsSharing {
                    Section {
                        Label(
                            "Sharing needs iCloud; the club stays on this iPhone.",
                            systemImage: "icloud.slash"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("New Book Club")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(isSubmitting || clubs.isBusy)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting || clubs.isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(!canCreate)
                }
            }
        }
        .interactiveDismissDisabled(isSubmitting || clubs.isBusy)
        .onAppear {
            bookID = library.selectedBookID ?? library.books.first?.id
            displayName = clubs.identity.displayName ?? UIDevice.current.name
        }
    }

    private var canCreate: Bool {
        !isSubmitting
            && !clubs.isBusy
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && bookID != nil
    }

    private func create() {
        guard canCreate, let bookID else { return }
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

/// Join club: the four-character code, typed on a monospaced field.
struct JoinClubSheet: View {
    @Environment(ClubModel.self) private var clubs
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var displayName = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Invite Code") {
                    TextField("ABCD", text: $code)
                        .font(.system(.title3, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                Section("Your Name") {
                    TextField("Your Name", text: $displayName)
                }
            }
            .navigationTitle("Join a Book Club")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(isSubmitting || clubs.isBusy)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting || clubs.isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join") { join() }
                        .disabled(!canJoin)
                }
            }
        }
        .interactiveDismissDisabled(isSubmitting || clubs.isBusy)
        .onAppear {
            displayName = clubs.identity.displayName ?? UIDevice.current.name
        }
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
