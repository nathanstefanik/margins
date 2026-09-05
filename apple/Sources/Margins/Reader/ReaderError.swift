import Foundation
import WebKit
import MarginsModel

enum ReaderError: Error {
    case unknownResource
    case missingBundledResource(String)
}
