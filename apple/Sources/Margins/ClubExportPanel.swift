import AppKit
import MarginsModel
import UniformTypeIdentifiers

/// The club export flow: `NSSavePanel` for the destination, then render the
/// merged document through `ClubModel` and write off the main actor. The
/// default name comes from the core's suggested filename.
enum ClubExportPanel {
    @MainActor
    static func run(model: ClubModel) async {
        guard let notes = model.notes else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = notes.suggestedFilename
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.message = "Export the club's compiled notes as a markdown file."
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let payload = await model.exportMarkdown() else { return }
        do {
            try await Task.detached(priority: .userInitiated) {
                try payload.markdown.write(to: url, atomically: true, encoding: .utf8)
            }.value
        } catch {
            model.errorMessage = String(describing: error)
        }
    }

    /// Copy-all without a save panel.
    @MainActor
    static func copy(model: ClubModel) async {
        guard let payload = await model.exportMarkdown() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload.markdown, forType: .string)
    }
}
