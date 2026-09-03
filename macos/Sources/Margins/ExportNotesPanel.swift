import AppKit
import MarginsCore
import MarginsModel
import UniformTypeIdentifiers

/// The compiled notes export flow: `NSSavePanel` for the destination, then
/// render through the core and write off the main actor. The default name
/// comes from the core (`suggested_filename`), shared with the Tauri app.
enum ExportNotesPanel {
    @MainActor
    static func run(model: LibraryModel, notes: CompiledNotes) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = notes.suggestedFilename
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.message = "Export the book's compiled notes as a markdown file."
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let markdown = try await model.renderNotesMarkdown(bookId: notes.bookId)
            try await Task.detached(priority: .userInitiated) {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
            }.value
        } catch {
            model.errorMessage = String(describing: error)
        }
    }
}
