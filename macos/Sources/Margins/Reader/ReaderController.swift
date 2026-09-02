import AppKit
import WebKit
import MarginsCore
import MarginsModel

/// Owns the reader's WKWebView: builds it, loads the reader page, enforces
/// the navigation policy (external links to the system browser), and bridges
/// model state into JavaScript calls.
@MainActor
final class ReaderController: NSObject {
    private let model: LibraryModel
    private let reader: ReaderModel
    private let keymap = ReaderKeymap(mode: .reader)
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
        configuration.userContentController.add(
            ReaderMessageProxy(controller: self),
            name: "readerKeys"
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

    func didReceiveScriptMessage(_ message: WKScriptMessage) {
        guard message.name == "readerKeys",
              let payload = message.body as? [String: Any]
        else { return }
        guard let key = payload["key"] as? String, !key.isEmpty else { return }

        let event = ReaderKeyEvent(
            key: key,
            ctrl: payload["ctrl"] as? Bool ?? false,
            meta: payload["meta"] as? Bool ?? false,
            shift: payload["shift"] as? Bool ?? false
        )
        for action in keymap.handle(event, now: ProcessInfo.processInfo.systemUptime) {
            perform(action)
        }
    }

    private func perform(_ action: ReaderAction) {
        switch action {
        case .scroll(let delta):
            evaluate("readerScrollBy(\(delta))")
        case .scrollTop:
            evaluate("readerScrollTop()")
        case .scrollBottom:
            evaluate("readerScrollBottom()")
        case .nextChapter:
            reader.nextChapter()
            displayCurrentChapter()
        case .previousChapter:
            reader.previousChapter()
            displayCurrentChapter()
        case .backToLibrary:
            reader.close()
        case .focusNotes, .search:
            // Notes and search arrive in Part III; the keymap already routes
            // the keys so nothing extra is needed when they land.
            break
        case .moveLibrarySelection, .openSelectedBook, .importBook:
            break
        }
    }

    /// Tells the page to display the model's current chapter.
    func displayCurrentChapter() {
        guard let href = reader.chapter?.href else { return }
        evaluate("readerDisplay(\(Self.javaScriptLiteral(href)))")
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

    private func evaluate(_ script: String) {
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    static func javaScriptLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8)
        else { return "''" }
        return literal
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
