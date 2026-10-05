import MarginsModel
import SwiftUI

/// Books-style typography popover: page theme (fixed paper, or day/night
/// papers following the system), typeface (Charter / Seravek / the
/// bundled Atkinson Hyperlegible Next), text size (A−/A+), line width,
/// and line height. Few controls, all backed by `ReaderPreferences`.
struct TypographyPopover: View {
    @Bindable var preferences: ReaderPreferences
    /// How many pages the renderer actually laid out, or nil while loading.
    /// Only used to explain a Two Pages fallback the user can see.
    var effectivePageCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Page Theme")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Toggle("Match system", isOn: $preferences.followsSystem)
                        .controlSize(.small)
                }
                if preferences.followsSystem {
                    paperRow("Day", themes: [.light, .sepia], selection: $preferences.dayTheme)
                    paperRow("Night", themes: [.dark, .night], selection: $preferences.nightTheme)
                } else {
                    HStack(spacing: 10) {
                        ForEach(ReaderTheme.allCases, id: \.self) { theme in
                            PaperSwatch(
                                theme: theme, selected: preferences.theme == theme
                            ) {
                                preferences.theme = theme
                            }
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Typeface")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Typeface", selection: $preferences.typeface) {
                    Text("Serif").tag(ReaderTypeface.serif)
                    Text("Sans").tag(ReaderTypeface.sans)
                    Text("Easy").tag(ReaderTypeface.easy)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Typeface")
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Justify text", isOn: $preferences.justify)
                Toggle("Chapter ornaments", isOn: $preferences.ornaments)
                    .help("Drop cap and small caps at chapter openings")
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Page Layout")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Page Layout", selection: $preferences.pageLayout) {
                    Text("Automatic").tag(ReaderPageLayout.automatic)
                    Text("One Page").tag(ReaderPageLayout.single)
                    Text("Two Pages").tag(ReaderPageLayout.double)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Page layout")
                if preferences.pageLayout == .double, effectivePageCount == 1 {
                    Text("One page shown — widen the window or reduce text size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(
                            "One page shown. Widen the window or reduce text size for two pages."
                        )
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Page Indicator")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Page Indicator", selection: $preferences.pageIndicator) {
                    ForEach(ReaderPageIndicator.allCases, id: \.self) { mode in
                        Text(mode.name).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Page indicator")
            }

            Divider()

            HStack(spacing: 10) {
                Text("Text Size")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    preferences.stepFontSize(-ReaderPreferences.fontSizeStep)
                } label: {
                    Text("A")
                        .font(.callout)
                        .frame(minWidth: 20)
                }
                .accessibilityLabel("Smaller text")
                .help("Smaller text (⌘−)")
                .disabled(!preferences.canStepFontSmaller)
                Text("\(Int(preferences.fontSize.rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 40)
                Button {
                    preferences.stepFontSize(ReaderPreferences.fontSizeStep)
                } label: {
                    Text("A")
                        .font(.title2)
                        .frame(minWidth: 20)
                }
                .accessibilityLabel("Bigger text")
                .help("Bigger text (⌘+)")
                .disabled(!preferences.canStepFontLarger)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Line Width")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Slider(
                    value: $preferences.lineWidth,
                    in: ReaderPreferences.lineWidthRange,
                    step: 2
                )
                .accessibilityLabel("Line width")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Line Height")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Slider(
                    value: $preferences.lineHeight,
                    in: ReaderPreferences.lineHeightRange,
                    step: 0.05
                )
                .accessibilityLabel("Line height")
            }

            Divider()

            HStack {
                Spacer(minLength: 0)
                Button("Reset", action: preferences.resetTypography)
                    .help("Restore default typography")
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    /// A labelled row of paper swatches, used for the day/night picks
    /// while the theme follows the system.
    private func paperRow(
        _ label: String,
        themes: [ReaderTheme],
        selection: Binding<ReaderTheme>
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            ForEach(themes, id: \.self) { theme in
                PaperSwatch(theme: theme, selected: selection.wrappedValue == theme) {
                    selection.wrappedValue = theme
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// A paper choice rendered as the paper itself: the background circle
/// with "Aa" in its ink and a selection ring.
private struct PaperSwatch: View {
    let theme: ReaderTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Aa")
                .font(.system(.callout, design: .serif))
                .foregroundStyle(Paper.ink(theme))
                .frame(width: 36, height: 36)
                .background(Paper.background(theme), in: .circle)
                .overlay {
                    Circle().strokeBorder(
                        selected ? Color.accentColor : Color.secondary.opacity(0.3),
                        lineWidth: selected ? 2 : 1
                    )
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
