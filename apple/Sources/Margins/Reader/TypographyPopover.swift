import SwiftUI
import MarginsModel

/// Books-style typography popover: text size (A−/A+), line width, and line
/// height. Few controls, all backed by `ReaderPreferences`.
struct TypographyPopover: View {
    @Bindable var preferences: ReaderPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
