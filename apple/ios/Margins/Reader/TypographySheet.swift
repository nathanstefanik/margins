import SwiftUI
import MarginsModel

/// Typography controls matching the macOS `TypographyPopover`: text size,
/// line height, and measure. Values persist through `ReaderPreferences`.
struct TypographySheet: View {
    @Bindable var preferences: ReaderPreferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Text size") {
                    HStack {
                        Button {
                            preferences.fontSize -= ReaderPreferences.fontSizeStep
                        } label: {
                            Image(systemName: "textformat.size.smaller")
                        }
                        .accessibilityLabel("Smaller text")
                        Slider(
                            value: Binding(
                                get: { preferences.fontSize },
                                set: { preferences.fontSize = $0.rounded() }
                            ),
                            in: ReaderPreferences.minFontSize...ReaderPreferences.maxFontSize,
                            step: ReaderPreferences.fontSizeStep
                        )
                        .accessibilityLabel("Text size")
                        Button {
                            preferences.fontSize += ReaderPreferences.fontSizeStep
                        } label: {
                            Image(systemName: "textformat.size.larger")
                        }
                        .accessibilityLabel("Bigger text")
                    }
                    LabeledContent("Size", value: "\(Int(preferences.fontSize))%")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Line height") {
                    Slider(
                        value: $preferences.lineHeight,
                        in: ReaderPreferences.lineHeightRange,
                        step: 0.1
                    )
                    .accessibilityLabel("Line height")
                    LabeledContent("Line height", value: String(format: "%.1f", preferences.lineHeight))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Measure") {
                    Slider(value: $preferences.lineWidth, in: ReaderPreferences.lineWidthRange, step: 2)
                        .accessibilityLabel("Line width")
                    LabeledContent("Line width", value: "\(Int(preferences.lineWidth)) ch")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Typography")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
