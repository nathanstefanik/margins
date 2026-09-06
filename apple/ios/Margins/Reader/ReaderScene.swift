import SwiftUI
import MarginsCore
import MarginsModel

/// The reader scene: the epub.js page full-bleed, with tap zones for
/// paging, a horizontally-swiping page turn, hardware-key support (iPad
/// keyboards share the ReaderKeymap's intent), and immersive chrome — a
/// minimal top/bottom bar that hides while reading and returns on a center
/// tap. Saving positions flushes on backgrounding: iOS will suspend you.
struct ReaderScene: View {
    @Environment(LibraryModel.self) private var library
    @Environment(ReaderModel.self) private var reader
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var chromeVisible = true
    @State private var typographyPresented = false
    @State private var tocPresented = false
    /// The representable's coordinator, handed over on creation; the
    /// chrome drives the page through it.
    @State private var bridge: ReaderBridge?

    var body: some View {
        ZStack {
            IOSReaderWebView(model: library, reader: reader, bridge: $bridge, onUserPageTurn: {
                chromeVisible = false
            })
                .ignoresSafeArea(edges: .bottom)
                .onTapGesture(coordinateSpace: .local) { location in
                    handleTap(at: location)
                }
                .gesture(pageSwipe)

            if chromeVisible {
                chrome
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: chromeVisible)
        .navigationTitle(reader.book?.title ?? "Reader")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(chromeVisible ? .visible : .hidden, for: .navigationBar)
        .sheet(isPresented: $typographyPresented) {
            TypographySheet(preferences: reader.preferences)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $tocPresented) {
            TOCSheet { chapter in
                jump(to: chapter)
            }
            .presentationDetents([.medium, .large])
        }
        .onChange(of: scenePhase) {
            // iOS suspends the app without warning: never lose position
            // (or a drafted note) to suspension.
            if scenePhase == .background {
                reader.flushPositionSave()
                reader.flushNoteSave()
            }
        }
        .onAppear {
            chromeVisible = true
        }
    }

    // MARK: Chrome

    @ViewBuilder
    private var chrome: some View {
        VStack {
            topBar
            Spacer(minLength: 0)
            bottomBar
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Back to book")
            Text(reader.chapter?.title ?? reader.book?.title ?? "Reader")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button {
                tocPresented = true
            } label: {
                Image(systemName: "list.bullet")
            }
            .accessibilityLabel("Table of contents")
            Button {
                typographyPresented = true
            } label: {
                Image(systemName: "textformat")
            }
            .accessibilityLabel("Typography")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Text(progressText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let percent = reader.bookPercent {
                ProgressView(value: percent, total: 100)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 160)
            }
            Spacer(minLength: 8)
            Button {
                // Phase 6: notes pane + capture.
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .disabled(true)
            .accessibilityLabel("Notes (arrives in Phase 6)")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var progressText: String {
        guard let progress = reader.progress else { return "" }
        return "\(progress.page) / \(max(progress.totalPages, 1))"
    }

    // MARK: Input

    private func handleTap(at location: CGPoint) {
        guard let width = tapZoneWidth else {
            chromeVisible.toggle()
            return
        }
        if location.x < width / 3 {
            pageBack()
        } else if location.x > width * 2 / 3 {
            pageForward()
        } else {
            chromeVisible.toggle()
        }
    }

    private var tapZoneWidth: CGFloat? {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.keyWindow
        else { return nil }
        return window.bounds.width
    }

    private var pageSwipe: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical) * 1.5 else { return }
                if horizontal < 0 {
                    pageForward()
                } else {
                    pageBack()
                }
            }
    }

    private func pageForward() {
        guard let bridge else { return }
        chromeVisible = false
        bridge.pageForward()
    }

    private func pageBack() {
        guard let bridge else { return }
        chromeVisible = false
        bridge.pageBack()
    }

    private func jump(to chapter: ChapterMeta) {
        guard let book = reader.book else { return }
        tocPresented = false
        chromeVisible = false
        reader.open(book: book, chapter: chapter)
        bridge?.jumpToChapter(chapter.jumpTarget)
    }
}

/// Sheet listing the book's spine; tapping jumps the reader there.
private struct TOCSheet: View {
    @Environment(ReaderModel.self) private var reader
    let onPick: (ChapterMeta) -> Void

    var body: some View {
        NavigationStack {
            List(reader.book?.chapters ?? []) { chapter in
                Button {
                    onPick(chapter)
                } label: {
                    HStack {
                        Text("\(chapter.index + 1)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 32, alignment: .trailing)
                        Text(chapter.title)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        if chapter.key == reader.chapter?.key {
                            Image(systemName: "bookmark.fill")
                                .font(.caption)
                                .foregroundStyle(.tint)
                                .accessibilityLabel("Current position")
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
