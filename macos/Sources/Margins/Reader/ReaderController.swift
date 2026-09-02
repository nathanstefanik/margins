import AppKit
import Observation
import WebKit
import MarginsCore
import MarginsModel

/// Owns the reader's WKWebView: builds it, loads the reader page, and
/// enforces the navigation policy (external links go to the system browser).
/// Keyboard routing lives in `ShellKeyboardController`, which injects calls
/// into the page via `evaluateJavaScript` using the `window.reader*` API
/// defined in `reader.js`. The page reports `relocated` events back through
/// the `reader` script message handler.
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
        let fallbackProvider: @Sendable (String) throws -> Data = { _ in
            throw CoreError.Message(message: "library is not open yet")
        }
        let bytesProvider = (try? model.makeReaderBytesProvider()) ?? fallbackProvider

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(
            ReaderSchemeHandler(bytesProvider: bytesProvider),
            forURLScheme: "margins-reader"
        )
        configuration.userContentController.add(self, name: "reader")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.webView = webView

        observeTypography()

        if let book = reader.book, let chapter = reader.chapter, let url = readerURL(bookID: book.id, chapterHref: chapter.href) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    /// Drops the script message handler when the view leaves the hierarchy:
    /// `add` retains this controller, which retains the webview, so without
    /// this every opened book would leak.
    func dismantle() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
        webView = nil
    }

    static func javaScriptLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8)
        else { return "''" }
        return literal
    }

    /// Evaluates a script in the open reader's page, whatever view is on
    /// top (the key monitor and menu commands both drive the webview this
    /// way). Returns false when no reader webview is on screen.
    @discardableResult
    static func evaluateInReader(_ script: String) -> Bool {
        guard let contentView = NSApp.keyWindow?.contentView,
              let webView = findWebView(in: contentView)
        else { return false }
        webView.evaluateJavaScript(script, completionHandler: nil)
        return true
    }

    static func findWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView {
            return webView
        }
        for subview in view.subviews {
            if let found = findWebView(in: subview) {
                return found
            }
        }
        return nil
    }

    // MARK: Typography

    /// Applies the current preferences to the page; the page stores the spec
    /// even before the rendition exists and applies it on open, and the
    /// content hook styles every section as it loads.
    private func applyTypography() {
        let preferences = reader.preferences
        evaluate(
            "readerApplyTypography(\(preferences.fontSize),\(preferences.lineHeight),\(preferences.lineWidth))"
        )
    }

    /// Re-applies typography whenever any preference changes.
    /// `withObservationTracking` is one-shot, so re-arm after each firing.
    private func observeTypography() {
        let preferences = reader.preferences
        withObservationTracking {
            _ = preferences.fontSize
            _ = preferences.lineHeight
            _ = preferences.lineWidth
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyTypography()
                self.observeTypography()
            }
        }
    }

    private func evaluate(_ script: String) {
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    private func readerURL(bookID: String, chapterHref: String) -> URL? {
        var components = URLComponents()
        components.scheme = "margins-reader"
        components.host = "app"
        components.path = "/reader.html"
        var queryItems = [
            URLQueryItem(name: "book", value: bookID),
            URLQueryItem(name: "chapter", value: chapterHref),
        ]
        if let cfi = reader.resumeCfi {
            queryItems.append(URLQueryItem(name: "cfi", value: cfi))
        }
        components.queryItems = queryItems
        return components.url
    }
}

extension ReaderController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // reader.js defines readerApplyTypography before its async open, so
        // this stores the current preferences for when the rendition appears.
        applyTypography()
    }
}

extension ReaderController: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "reader", let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "relocated":
            let page = (body["page"] as? NSNumber)?.intValue ?? 1
            let totalPages = (body["totalPages"] as? NSNumber)?.intValue ?? 0
            reader.relocated(
                page: page,
                totalPages: totalPages,
                href: body["href"] as? String,
                cfi: body["cfi"] as? String
            )
        default:
            break
        }
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
