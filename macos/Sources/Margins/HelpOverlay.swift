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
                        .font(.title3)
                    Spacer()
                    Text("esc")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                }
                .padding(18)

                Divider()

                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 28), GridItem(.flexible())],
                        alignment: .leading,
                        spacing: 26
                    ) {
                        ForEach(ReaderKeymap.helpGroups(), id: \.name) { group in
                            keyGroup(group)
                        }
                    }
                    .padding(20)
                }
                .frame(maxHeight: 500)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
            .frame(width: 720)
            .padding(.top, 40)
            .contentShape(.rect)
            .onTapGesture {}
        }
    }

    private func keyGroup(_ group: KeyHelpGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.name)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(Array(group.entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    HStack(spacing: 5) {
                        ForEach(entry.keys, id: \.self) { key in
                            Text(prettified(key))
                                .font(.callout.monospaced())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    .quaternary.opacity(0.7),
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                        }
                    }
                    Spacer(minLength: 12)
                    Text(entry.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    /// Raw keymap names become keycap-ish labels: "Space", "Esc", "→".
    private func prettified(_ key: String) -> String {
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
}
