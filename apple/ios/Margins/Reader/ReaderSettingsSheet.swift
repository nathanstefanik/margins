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

/// The hamburger menu: the reading-surface theme (a fixed paper, or
/// day/night papers following the system), text size as a small-A /
/// large-A pair — the ladder behind it is internal, no numbers — a
/// Serif/Sans/Easy typeface switch (Charter / Seravek / the bundled
/// Atkinson Hyperlegible Next), plus Contents, Bookmarks, Marks, and the
/// chapter note, which lost their bars when the chrome went quiet.
/// No line height, no measure.
struct ReaderSettingsSheet: View {
    @Bindable var preferences: ReaderPreferences
    let onSelect: (ReaderDestination) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Toggle("Match system appearance", isOn: $preferences.followsSystem)
                        .accessibilityIdentifier("reader-follows-system")
                    if preferences.followsSystem {
                        paperRow(
                            "Day", themes: [.light, .sepia], selection: $preferences.dayTheme)
                        paperRow(
                            "Night", themes: [.dark, .night], selection: $preferences.nightTheme)
                    } else {
                        paperRow("Paper", themes: ReaderTheme.allCases, selection: $preferences.theme)
                    }
                }
                Section("Text layout") {
                    Toggle("Justify text", isOn: $preferences.justify)
                        .accessibilityIdentifier("reader-justify")
                    Toggle("Chapter ornaments", isOn: $preferences.ornaments)
                        .accessibilityIdentifier("reader-ornaments")
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
                    .sensoryFeedback(.selection, trigger: preferences.fontStep)
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
                Section("Page indicator") {
                    Picker("Page indicator", selection: $preferences.pageIndicator) {
                        ForEach(ReaderPageIndicator.allCases, id: \.self) { mode in
                            Text(mode.name).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("reader-page-indicator")
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

    /// A labelled row of paper swatches — the paper's own colors, so the
    /// choice reads as the paper it paints.
    private func paperRow(
        _ label: String,
        themes: [ReaderTheme],
        selection: Binding<ReaderTheme>
    ) -> some View {
        HStack(spacing: DesignTokens.Spacing.actions) {
            Text(label)
            Spacer(minLength: 0)
            ForEach(themes, id: \.self) { theme in
                PaperSwatch(theme: theme, selected: selection.wrappedValue == theme) {
                    selection.wrappedValue = theme
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

/// A paper choice rendered as the paper itself: a filled circle carrying
/// "Aa" in the paper's ink, ringed when selected.
private struct PaperSwatch: View {
    let theme: ReaderTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Aa")
                .font(.system(.body, design: .serif))
                .foregroundStyle(DesignTokens.Paper.ink(theme))
                .frame(
                    width: DesignTokens.Control.minimumTarget,
                    height: DesignTokens.Control.minimumTarget
                )
                .background(DesignTokens.Paper.background(theme), in: .circle)
                .overlay {
                    Circle().strokeBorder(
                        selected ? Color.accentColor : Color.secondary.opacity(0.3),
                        lineWidth: selected ? 2.5 : 1
                    )
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.name)
        .accessibilityIdentifier("reader-paper-\(theme.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
