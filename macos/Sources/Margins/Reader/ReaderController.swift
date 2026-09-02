import AppKit
import WebKit
import MarginsCore
import MarginsModel

/// Owns the reader's WKWebView: builds it, loads the reader page, and
/// enforces the navigation policy (external links go to the system browser).
/// Keyboard routing lives in `ShellKeyboardController`, which injects calls
/// into the page via `evaluateJavaScript` using the `window.reader*` API
/// defined in `reader.js`.
@MainActor
final class ReaderController: NSObject {
    private let model: LibraryModel
    private let reader: ReaderModel
    private var webView: WKWebView?

    init(model: LibraryModel, reader: ReaderModel) {
        self.model = model
        self.reader = reader
        super.init()
    }

    func makeWebView() -> WKWebView {
        let bytesProvider = (try? model.makeReaderBytesProvider()) ?? { _ in
            throw CoreError.Message(message: "library is not open yet")
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(
            ReaderSchemeHandler(bytesProvider: bytesProvider),
            forURLScheme: "margins-reader"
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.webView = webView

        if let book = reader.book, let chapter = reader.chapter, let url = readerURL(bookID: book.id, chapterHref: chapter.href) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    static func javaScriptLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8)
        else { return "''" }
        return literal
    }

    private func readerURL(bookID: String, chapterHref: String) -> URL? {
        var components = URLComponents()
        components.scheme = "margins-reader"
        components.host = "app"
        components.path = "/reader.html"
        components.queryItems = [
            URLQueryItem(name: "book", value: bookID),
            URLQueryItem(name: "chapter", value: chapterHref),
        ]
        return components.url
    }
}

extension ReaderController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

extension ReaderController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}
