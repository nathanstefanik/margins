import SwiftUI
import UniformTypeIdentifiers
import MarginsCore
import MarginsModel

/// New club: name it, pick the one book it reads, set the name others see.
struct CreateClubSheet: View {
    @Environment(ClubModel.self) private var clubs
    @Environment(LibraryModel.self) private var library
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var displayName = ""
    @State private var bookID: String?
    @State private var isSubmitting = false
    @State private var importPresented = false

    var body: some View {
        NavigationStack {
            Group {
                if library.books.isEmpty {
                    ContentUnavailableView {
                        Label("No books yet", systemImage: "book")
                    } description: {
                        Text("A club reads one book from your library. Import an EPUB first.")
                    } actions: {
                        Button("Import EPUB") { importPresented = true }
                    }
                } else {
                    Form {
                        Section("Club") {
                            TextField("Club Name", text: $name)
                            TextField("Name", text: $displayName)
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
                if !library.books.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") { create() }
                            .disabled(!canCreate)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSubmitting || clubs.isBusy)
        .fileImporter(
            isPresented: $importPresented,
            allowedContentTypes: [.epub, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .failure(let error):
                library.errorMessage = String(describing: error)
            case .success(let urls):
                guard let picked = urls.first else { return }
                Task { await app.importSecurityScoped(picked) }
            }
        }
        .onAppear {
            if displayName.isEmpty, let saved = clubs.identity.displayName {
                displayName = saved
            }
            bookID = library.selectedBookID ?? library.books.first?.id
        }
        .onChange(of: library.books.count) {
            if bookID == nil {
                bookID = library.selectedBookID ?? library.books.first?.id
            }
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
                Section("Name") {
                    TextField("Name", text: $displayName)
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
            if displayName.isEmpty, let saved = clubs.identity.displayName {
                displayName = saved
            }
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
