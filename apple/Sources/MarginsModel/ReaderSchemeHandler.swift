import Foundation
import WebKit

/// Serves the five fixed `margins-reader://` resources. Everything else —
/// traversal, nested paths, unknown names — fails without touching the
/// filesystem beyond the vendored reader directory.
///
/// Lives in MarginsModel so the macOS app and the iOS app serve the exact
/// same allowlist from the same vendored assets (this target's resource
/// bundle). The load-bearing response-type rules are documented inline and
/// in docs/architecture.md.
public final class ReaderSchemeHandler: NSObject, WKURLSchemeHandler {
    private let bytesProvider: @Sendable (String) throws -> Data

    public init(bytesProvider: @escaping @Sendable (String) throws -> Data) {
        self.bytesProvider = bytesProvider
        super.init()
    }

    public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
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

            // fetch() requires HTTP semantics: a plain URLResponse makes
            // WebKit reject the fetch with status 0. Frame loads (html/js)
            // need the plain URLResponse — HTTP there breaks the load.
            let response: URLResponse
            if resource == .bookEpub {
                response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Length": "\(data.count)"]
                ) ?? URLResponse(
                    url: url,
                    mimeType: resource.mimeType,
                    expectedContentLength: data.count,
                    textEncodingName: nil
                )
            } else {
                response = URLResponse(
                    url: url,
                    mimeType: resource.mimeType,
                    expectedContentLength: data.count,
                    textEncodingName: resource.textEncodingName
                )
            }
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        } catch {
            task.didFailWithError(error)
        }
    }

    public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // Responses are delivered synchronously in start; nothing to cancel.
    }
}
