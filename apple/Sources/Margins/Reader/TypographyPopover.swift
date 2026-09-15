import SwiftUI
import MarginsModel

/// Books-style typography popover: page theme (cream paper or dark), text
/// size (A−/A+), line width, and line height. Few controls, all backed by
/// `ReaderPreferences`.
struct TypographyPopover: View {
    @Bindable var preferences: ReaderPreferences
    /// How many pages the renderer actually laid out, or nil while loading.
    /// Only used to explain a Two Pages fallback the user can see.
    var effectivePageCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Page Theme")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Page Theme", selection: $preferences.theme) {
                    Text("Light").tag(ReaderTheme.light)
                    Text("Dark").tag(ReaderTheme.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
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
}
