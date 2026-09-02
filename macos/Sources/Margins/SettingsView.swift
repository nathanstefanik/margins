import SwiftUI
import MarginsModel

/// Real Settings content: the reader's typography defaults and the library
/// root. Both drive the same persisted state the reading surface uses.
struct SettingsView: View {
    let model: LibraryModel
    let reader: ReaderModel

    var body: some View {
        TabView {
            typographyTab
                .tabItem { Label("Reading", systemImage: "book") }
            libraryTab
                .tabItem { Label("Library", systemImage: "folder") }
        }
        .frame(width: 420, height: 260)
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
