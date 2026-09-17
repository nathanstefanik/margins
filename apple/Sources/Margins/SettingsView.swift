import SwiftUI
import MarginsModel

/// Real Settings content: the reader's typography defaults and the library
/// root. Both drive the same persisted state the reading surface uses.
struct SettingsView: View {
    let model: LibraryModel
    let clubs: ClubModel
    let reader: ReaderModel

    @State private var displayName = ""

    var body: some View {
        TabView {
            typographyTab
                .tabItem { Label("Reading", systemImage: "book") }
            libraryTab
                .tabItem { Label("Library", systemImage: "folder") }
            clubsTab
                .tabItem { Label("Clubs", systemImage: "person.2") }
        }
        .frame(width: 420, height: 360)
        .onAppear { displayName = clubs.identity.displayName ?? "" }
        .onDisappear {
            let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            Task { await clubs.setDisplayName(name) }
        }
    }

    private var clubsTab: some View {
        Form {
            Section("Book Clubs") {
                TextField("Name", text: $displayName)
                    .onSubmit { Task { await clubs.setDisplayName(displayName) } }
                Text("The name other members see, on every club.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(
                    "Spoiler protection",
                    isOn: Binding(
                        get: { clubs.spoilerProtection },
                        set: { value in Task { await clubs.setSpoilerProtection(value) } }
                    )
                )
                Text("Hide another member's notes for the chapter you're reading and every later chapter. Your own notes always stay visible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Sharing") {
                    Text(clubs.supportsSharing ? "iCloud" : "This Mac only")
                }
                Text(
                    clubs.supportsSharing
                        ? "Clubs are private: members join only with an invite code you share."
                        : "Sign in to iCloud in System Settings to invite other readers. Until then clubs stay on this Mac."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var typographyTab: some View {
        Form {
            Section("Typography") {
                HStack {
                    Text("Text Size")
                    Spacer()
                    Button {
                        reader.preferences.stepFontSize(-ReaderPreferences.fontSizeStep)
                    } label: {
                        Text("A").font(.callout)
                    }
                    .accessibilityLabel("Smaller text")
                    Text("\(Int(reader.preferences.fontSize.rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button {
                        reader.preferences.stepFontSize(ReaderPreferences.fontSizeStep)
                    } label: {
                        Text("A").font(.title2)
                    }
                    .accessibilityLabel("Bigger text")
                }
                LabeledContent("Line Width") {
                    Slider(
                        value: Binding(
                            get: { reader.preferences.lineWidth },
                            set: { reader.preferences.lineWidth = $0 }
                        ),
                        in: ReaderPreferences.lineWidthRange,
                        step: 2
                    )
                    .frame(width: 180)
                }
                LabeledContent("Line Height") {
                    Slider(
                        value: Binding(
                            get: { reader.preferences.lineHeight },
                            set: { reader.preferences.lineHeight = $0 }
                        ),
                        in: ReaderPreferences.lineHeightRange,
                        step: 0.05
                    )
                    .frame(width: 180)
                }
                HStack {
                    Spacer()
                    Button("Reset Typography", action: reader.preferences.resetTypography)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var libraryTab: some View {
        Form {
            Section("Library Directory") {
                LabeledContent("Current") {
                    Text(model.libraryRoot)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(model.libraryRoot)
                }
                HStack {
                    Spacer()
                    Button("Choose…") {
                        Task { await RootPanel.run(model: model) }
                    }
                }
                Text("Books, notes, covers, and reading positions live here. Point it at a synced folder to share the library between machines.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
