import Foundation
import MarginsCore

/// Sheet-draft for editing a mark's text; keeps the original mark around
/// for the update call.
struct MarkDraft: Identifiable {
    let id: String
    let mark: Mark
    var body: String

    init(mark: Mark) {
        id = mark.id
        self.mark = mark
        body = mark.body
    }
}
