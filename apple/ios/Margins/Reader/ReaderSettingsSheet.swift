import MarginsModel
import SwiftUI

/// Where the hamburger menu can send the reader. The scene presents the
/// matching sheet once the menu has dismissed.
enum ReaderDestination {
    case contents
    case bookmarks
    case marks
    case chapterNote
    case searchLibrary
}

/// The hamburger menu: the reading-surface theme (cream paper or dark), text
/// size as a small-A / large-A pair — the ladder behind it is internal, no
/// numbers — a Serif/Sans/Easy typeface switch (Charter / Seravek / the
/// bundled Atkinson Hyperlegible Next), plus Contents, Bookmarks, Marks,
/// and the chapter note, which lost their bars when the chrome went quiet.
/// No line height, no measure.
struct ReaderSettingsSheet: View {
    @Bindable var preferences: ReaderPreferences
    let onSelect: (ReaderDestination) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $preferences.theme) {
                        Text("Light").tag(ReaderTheme.light)
                        Text("Dark").tag(ReaderTheme.dark)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Reading theme")
                }
                Section("Text size") {
                    HStack(spacing: DesignTokens.Spacing.actions) {
                        Button {
                            preferences.stepFont(-1)
                        } label: {
                            Text("A")
                                .font(.system(size: 16, weight: .medium))
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: DesignTokens.Control.fontSizeLabelHeight
                                )
                                .contentShape(Rectangle())
                        }
                        .disabled(!preferences.canStepFontSmaller)
                        .accessibilityLabel("Smaller text")
                        .accessibilityIdentifier("reader-smaller-text")
                        Button {
                            preferences.stepFont(1)
                        } label: {
                            Text("A")
                                .font(.system(size: 30, weight: .medium))
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: DesignTokens.Control.fontSizeLabelHeight
                                )
                                .contentShape(Rectangle())
                        }
                        .disabled(!preferences.canStepFontLarger)
                        .accessibilityLabel("Larger text")
                        .accessibilityIdentifier("reader-larger-text")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
                Section("Typeface") {
                    Picker("Typeface", selection: $preferences.typeface) {
                        Text("Serif").tag(ReaderTypeface.serif)
                        Text("Sans").tag(ReaderTypeface.sans)
                        Text("Easy").tag(ReaderTypeface.easy)
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    destinationButton("Contents", systemImage: "list.bullet", destination: .contents)
                    destinationButton("Bookmarks", systemImage: "bookmark", destination: .bookmarks)
                    destinationButton("Marks", systemImage: "highlighter", destination: .marks)
                    destinationButton(
                        "Chapter note", systemImage: "square.and.pencil", destination: .chapterNote
                    )
                    destinationButton(
                        "Search Library", systemImage: "magnifyingglass",
                        destination: .searchLibrary)
                }
            }
            .navigationTitle("Reader")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
    }

    private func destinationButton(
        _ title: String,
        systemImage: String,
        destination: ReaderDestination
    ) -> some View {
        Button {
            onSelect(destination)
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
    }
}
