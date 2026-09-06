import Foundation
import WebKit

/// Failures the reader scheme handler reports for bad resource requests.
public enum ReaderError: Error {
    case unknownResource
    case missingBundledResource(String)
}
