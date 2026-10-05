import MarginsModel
import SwiftUI

/// Thin, unobtrusive progress footer under the page: the current chapter
/// title and the position within the chapter. Styled with the paper palette
/// so page and footer read as one surface.
struct ReaderFooter: View {
    let reader: ReaderModel

    /// Hover/drag state for the scrubber that replaces the page text.
    @State private var hovering = false
    @State private var scrubbing = false
    @State private var scrubValue: Double = 1

    var body: some View {
        HStack(spacing: 12) {
            Text(reader.chapter?.title ?? "")
                .lineLimit(1)
                .truncationMode(.tail)
                .help(reader.chapter?.title ?? "")
            Spacer(minLength: 0)
            if let progress = reader.progress, progress.totalPages > 0 {
                if hovering || scrubbing {
                    HStack(spacing: 8) {
                        Slider(
                            value: $scrubValue,
                            in: 1...Double(progress.totalPages),
                            step: 1,
                            onEditingChanged: { editing in
                                scrubbing = editing
                                if !editing {
                                    ReaderController.goToPage(Int(scrubValue))
                                }
                            }
                        )
                        .controlSize(.small)
                        .frame(width: 200)
                        .accessibilityLabel("Page")
                        .accessibilityValue(
                            "\(Int(scrubValue)) of \(progress.totalPages)")
                        Text(pageLabel(for: progress))
                            .monospacedDigit()
                    }
                } else {
                    Text(pageLabel(for: progress))
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
        // The page text becomes a scrubber under the pointer; leaving the
        // footer mid-drag keeps the slider alive until the drag ends.
        .onHover { inside in
            if inside, let progress = reader.progress, !scrubbing {
                scrubValue = Double(progress.page)
            }
            hovering = inside
        }
        .onChange(of: reader.progress?.page) {
            if !scrubbing, let page = reader.progress?.page {
                scrubValue = Double(page)
            }
        }
    }

    /// A verified spread reads as a range; a single page (or one whose
    /// endpoints could not be verified) reads as before.
    private func pageLabel(for progress: ReaderProgress) -> String {
        if let endPage = progress.endPage, endPage > progress.page {
            return "Pages \(progress.page)–\(endPage) of \(progress.totalPages)"
        }
        return "Page \(progress.page) of \(progress.totalPages)"
    }
}
