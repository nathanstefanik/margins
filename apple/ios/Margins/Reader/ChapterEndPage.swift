import MarginsCore
import MarginsModel
import SwiftUI

/// The end-of-chapter page: an opaque paper sheet over the reading surface
/// that pauses once per finished chapter — a couple of its marked quotes,
/// a taste of its note, and the offer to write something. A tap or swipe
/// anywhere outside the buttons continues; hardware page keys dismiss via
/// `KeyHandlingWebView`.
struct ChapterEndPage: View {
    let chapter: ChapterMeta
    let theme: ReaderTheme
    let face: String
    /// true for "Write a thought", false for any other dismissal.
    let onDismiss: (Bool) -> Void
    let loadContent: () async -> ChapterEndContent?

    @State private var content: ChapterEndContent?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(content?.label ?? "END OF CHAPTER")
                    .font(.system(size: 12, weight: .medium, design: .serif).smallCaps())
                    .tracking(1.4)
                    .foregroundStyle(DesignTokens.Paper.secondaryInk(theme))
                Text(chapter.title)
                    .font(.custom(face, size: 24, relativeTo: .title2).weight(.semibold))
                    .foregroundStyle(DesignTokens.Paper.ink(theme))
                    .lineLimit(4)

                if let content {
                    ForEach(content.quotes.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: 10) {
                            Rectangle()
                                .fill(DesignTokens.Paper.secondaryInk(theme).opacity(0.35))
                                .frame(width: 2)
                            Text(content.quotes[index])
                                .font(.custom(face, size: 15, relativeTo: .body).italic())
                                .foregroundStyle(DesignTokens.Paper.ink(theme))
                                .lineLimit(4)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if !content.excerpt.isEmpty {
                        Text(content.excerpt)
                            .font(.callout)
                            .foregroundStyle(DesignTokens.Paper.secondaryInk(theme))
                            .lineLimit(2)
                    }
                }

                Text("Anything worth keeping?")
                    .font(.callout)
                    .foregroundStyle(DesignTokens.Paper.secondaryInk(theme))

                HStack(spacing: DesignTokens.Spacing.actions) {
                    Button { onDismiss(true) } label: {
                        Text("Write a thought")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { onDismiss(false) } label: {
                        Text("Continue")
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 32)
            .padding(.top, 72)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Content, not chrome: the sheet is the paper itself.
        .background(DesignTokens.Paper.background(theme).ignoresSafeArea())
        .environment(\.colorScheme, theme.palette.isDark ? .dark : .light)
        // Catch the page's own tap zones and swipes: the sheet owns all
        // touches, and they continue instead of turning under it.
        .contentShape(Rectangle())
        .onTapGesture { onDismiss(false) }
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { _ in onDismiss(false) }
        )
        .task(id: chapter.key) {
            content = await loadContent()
        }
        .accessibilityElement(children: .contain)
    }
}
