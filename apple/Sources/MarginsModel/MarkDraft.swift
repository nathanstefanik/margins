import Foundation
import MarginsKernel

/// Sheet-draft for editing a mark's text; keeps the original mark around
/// for the update call.
public struct MarkDraft: Identifiable {
    public let id: String
    public let mark: Mark
    public var body: String

    public init(mark: Mark) {
        id = mark.id
        self.mark = mark
        body = mark.body
    }
}
