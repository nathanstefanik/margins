import SwiftUI
import MarginsModel

/// Thin, unobtrusive progress footer under the page: the current chapter
/// title and the position within the chapter. Styled with the paper palette
/// so page and footer read as one surface.
struct ReaderFooter: View {
    let reader: ReaderModel

    var body: some View {
        HStack(spacing: 12) {
            Text(reader.chapter?.title ?? "")
                .lineLimit(1)
                .truncationMode(.tail)
                .help(reader.chapter?.title ?? "")
            Spacer(minLength: 0)
            if let progress = reader.progress, progress.totalPages > 0 {
                // A verified spread reads as a range; a single page (or one
                // whose endpoints could not be verified) reads as before.
                if let endPage = progress.endPage, endPage > progress.page {
                    Text("Pages \(progress.page)–\(endPage) of \(progress.totalPages)")
                        .monospacedDigit()
                } else {
                    Text("Page \(progress.page) of \(progress.totalPages)")
                        .monospacedDigit()
                }
            }
        }
        .font(.caption)
        .foregroundStyle(Paper.secondaryInk(reader.preferences.theme))
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(Paper.background(reader.preferences.theme))
        .textSelection(.disabled)
        .accessibilityElement(children: .combine)
    }
}
