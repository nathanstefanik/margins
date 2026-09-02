import SwiftUI
import MarginsModel

/// The `?` cheat sheet: every vim-style key, grouped by context, generated
/// from the keymap's help model. Presented in-window with the same scrim
/// and dismissal pattern as the search palette; Esc or a click outside
/// closes it.
struct HelpOverlay: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(.rect)
                .onTapGesture { model.requestHelpDismissal() }

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(.headline)
                    Spacer()
                    Text("esc")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
                }
                .padding(16)

                Divider()

                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible())],
                        alignment: .leading,
                        spacing: 20
                    ) {
                        ForEach(ReaderKeymap.helpGroups(), id: \.name) { group in
                            keyGroup(group)
                        }
                    }
                    .padding(16)
                }
                .frame(maxHeight: 440)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
            .frame(width: 640)
            .padding(.top, 40)
            .contentShape(.rect)
            .onTapGesture {}
        }
    }

    private func keyGroup(_ group: KeyHelpGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.name)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(Array(group.entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(prettified(entry.keys))
                        .font(.caption.monospaced())
                    Spacer(minLength: 8)
                    Text(entry.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    /// Raw keymap names become keycap-ish labels: "Space", "Esc", "→".
    private func prettified(_ keys: [String]) -> String {
        keys
            .map { key -> String in
                switch key {
                case " ":
                    return "Space"
                case "Escape":
                    return "Esc"
                case "ArrowRight":
                    return "→"
                case "ArrowLeft":
                    return "←"
                case "ArrowUp":
                    return "↑"
                case "ArrowDown":
                    return "↓"
                case "PageUp":
                    return "PgUp"
                case "PageDown":
                    return "PgDn"
                default:
                    return key
                }
            }
            .joined(separator: " / ")
    }
}
