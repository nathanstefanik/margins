import MarginsCore
import SwiftUI

/// Where a passage-like result lands: the reader at `cfi` when one is
/// known, otherwise the chapter with the reveal armed to locate
/// `revealText` (which may backfill `markId`'s CFI). Book-level targets
/// pass an empty `chapterKey`.
struct PassageTarget: Hashable {
    var bookId: String
    var chapterKey: String
    var cfi: String?
    var revealText: String?
    var markId: String?

    init(
        bookId: String, chapterKey: String,
        cfi: String? = nil, revealText: String? = nil, markId: String? = nil
    ) {
        self.bookId = bookId
        self.chapterKey = chapterKey
        self.cfi = cfi
        self.revealText = revealText
        self.markId = markId
    }
}

/// Opens a passage in the reader — from search results, notebook cards,
/// or mark citations. Installed by `LibraryScene`, which owns the
/// navigation; default is a no-op for previews and tests.
struct OpenPassageAction {
    private let handler: (PassageTarget) -> Void

    init(handler: @escaping (PassageTarget) -> Void = { _ in }) {
        self.handler = handler
    }

    func callAsFunction(_ target: PassageTarget) {
        handler(target)
    }
}

/// Pushes a notebook onto the Notebooks tab's stack.
struct OpenNotebookAction {
    private let handler: (String) -> Void

    init(handler: @escaping (String) -> Void = { _ in }) {
        self.handler = handler
    }

    func callAsFunction(_ notebookId: String) {
        handler(notebookId)
    }
}

private struct OpenPassageKey: EnvironmentKey {
    static let defaultValue = OpenPassageAction()
}

private struct OpenNotebookKey: EnvironmentKey {
    static let defaultValue = OpenNotebookAction()
}

extension EnvironmentValues {
    var openPassage: OpenPassageAction {
        get { self[OpenPassageKey.self] }
        set { self[OpenPassageKey.self] = newValue }
    }

    var openNotebook: OpenNotebookAction {
        get { self[OpenNotebookKey.self] }
        set { self[OpenNotebookKey.self] = newValue }
    }
}
