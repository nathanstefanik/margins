import Foundation
import WebKit
import MarginsModel

/// Serves the five fixed `margins-reader://` resources. Everything else —
/// traversal, nested paths, unknown names — fails without touching the
/// filesystem beyond the vendored reader directory.
final class ReaderSchemeHandler: NSObject, WKURLSchemeHandler {
    private let bytesProvider: @Sendable (String) throws -> Data

    init(bytesProvider: @escaping @Sendable (String) throws -> Data) {
        self.bytesProvider = bytesProvider
        super.init()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let resource = ReaderResource(path: url.path) else {
            task.didFailWithError(ReaderError.unknownResource)
            return
        }

        do {
            let data: Data
            switch resource {
            case .bookEpub:
                let bookID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first { $0.name == "book" }?
                    .value ?? ""
                data = try bytesProvider(bookID)
            default:
                guard let fileURL = Bundle.module.url(
                    forResource: resource.fileName,
                    withExtension: resource.fileExtension,
                    subdirectory: "reader"
                ) else {
                    throw ReaderError.missingBundledResource(resource.rawValue)
                }
                data = try Data(contentsOf: fileURL)
            }

            let response = URLResponse(
                url: url,
                mimeType: resource.mimeType,
                expectedContentLength: data.count,
                textEncodingName: resource.textEncodingName
            )
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        } catch {
            task.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // Responses are delivered synchronously in start; nothing to cancel.
    }
}
