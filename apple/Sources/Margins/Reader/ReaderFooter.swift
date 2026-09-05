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
                Text("Page \(progress.page) of \(progress.totalPages)")
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(Paper.secondaryInk)
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(Paper.background)
        .textSelection(.disabled)
        .accessibilityElement(children: .combine)
    }
}
