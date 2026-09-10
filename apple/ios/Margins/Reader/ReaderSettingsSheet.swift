import SwiftUI
import MarginsModel

/// Where the hamburger menu can send the reader. The scene presents the
/// matching sheet once the menu has dismissed.
enum ReaderDestination {
    case contents
    case marks
    case chapterNote
}

/// The hamburger menu: text size as a small-A / large-A pair — the ladder
/// behind it is internal, no numbers — plus Contents, Marks, and the
/// chapter note, which lost their bars when the chrome went quiet. No
/// line height, no measure.
struct ReaderSettingsSheet: View {
    @Bindable var preferences: ReaderPreferences
    let onSelect: (ReaderDestination) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Text size") {
                    HStack {
                        Button {
                            preferences.stepFont(-1)
                        } label: {
                            Text("A")
                                .font(.system(size: 16, weight: .medium))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .disabled(!preferences.canStepFontSmaller)
                        .accessibilityLabel("Smaller text")
                        Button {
                            preferences.stepFont(1)
                        } label: {
                            Text("A")
                                .font(.system(size: 30, weight: .medium))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .disabled(!preferences.canStepFontLarger)
                        .accessibilityLabel("Larger text")
                    }
                    .buttonStyle(.borderless)
                }
                Section {
                    Button { onSelect(.contents) } label: {
                        Label("Contents", systemImage: "list.bullet")
                    }
                    Button { onSelect(.marks) } label: {
                        Label("Marks", systemImage: "highlighter")
                    }
                    Button { onSelect(.chapterNote) } label: {
                        Label("Chapter note", systemImage: "square.and.pencil")
                    }
                }
            }
            .navigationTitle("Reader")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
