import SwiftUI
import UIKit
import WebKit
import MarginsCore
import MarginsModel

/// Hardware-key page turns: the WKWebView is first responder when reading,
/// so arrow/space presses are intercepted here before the web view can
/// swallow them — the iOS analogue of the macOS shell key monitor.
final class KeyHandlingWebView: WKWebView {
    enum PageDirection {
        case forward
        case back
    }

    var onKey: ((PageDirection) -> Void)?
    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if handle(presses) { return }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if handle(presses) { return }
        super.pressesEnded(presses, with: event)
    }

    private func handle(_ presses: Set<UIPress>) -> Bool {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            switch key.keyCode {
            case .keyboardRightArrow, .keyboardDownArrow, .keyboardSpacebar:
                onKey?(.forward)
                handled = true
            case .keyboardLeftArrow, .keyboardUpArrow:
                onKey?(.back)
                handled = true
            default:
                break
            }
        }
        return handled
    }
}

/// The reader's WKWebView for iOS: builds it, loads the reader page, and
/// enforces the navigation policy (external links leave for Safari). The
/// page reports `relocated` events back through the `reader` script message
/// handler; Swift drives it through the `window.reader*` functions defined
/// in `reader.js` — the same contract as the macOS app.
struct IOSReaderWebView: UIViewRepresentable {
    let model: LibraryModel
    let reader: ReaderModel
    @Binding var bridge: ReaderBridge?
    var onUserPageTurn: () -> Void = {}

    func makeCoordinator() -> ReaderBridge {
        ReaderBridge(model: model, reader: reader)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = context.coordinator.makeWebView()
        bridge = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Keep the callback current: the coordinator was created once, but
        // the scene's closure captures per-render state.
        context.coordinator.onUserPageTurn = onUserPageTurn
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: ReaderBridge) {
        coordinator.dismantle()
    }
}

/// Owns the reader webview and exposes page-turn/jump evaluation to the
/// scene (tap zones, swipes, hardware keys).
@MainActor
final class ReaderBridge: NSObject {
    private let model: LibraryModel
    private let reader: ReaderModel
    private var webView: WKWebView?
    /// Set by the scene: any user-driven page turn hides the chrome.
    var onUserPageTurn: (() -> Void)?

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
        // Pipe the page's console + fatal errors into the native log: the
        // reader's failure modes (bad EPUB, epub.js quirks) would otherwise
        // be invisible.
        let consoleScript = WKUserScript(
            source: """
            (function() {
                var send = function(level, text) {
                    try { window.webkit.messageHandlers.reader.postMessage({ type: 'console', level: level, text: text }); } catch (e) {}
                };
                var forward = function(level) {
                    var orig = console[level];
                    console[level] = function() {
                        send(level, Array.prototype.join.call(arguments, ' '));
                        orig.apply(console, arguments);
                    };
                };
                forward('log');
                forward('error');
                window.onerror = function(msg, src, line, col) {
                    send('onerror', msg + ' @' + src + ':' + line + ':' + col);
                };
                window.addEventListener('unhandledrejection', function(event) {
                    var reason = event.reason && (event.reason.stack || event.reason.message || event.reason);
                    send('unhandledrejection', String(reason));
                });
                setTimeout(function() {
                    var v = document.getElementById('viewer');
                    var r = v && v.getBoundingClientRect();
                    var iframes = document.querySelectorAll('iframe');
                    var ir = iframes.length ? iframes[0].getBoundingClientRect() : null;
                    send('diag', 'viewer=' + JSON.stringify(r) + ' iframes=' + iframes.length
                        + ' iframe0=' + JSON.stringify(ir)
                        + ' bodyH=' + document.body.scrollHeight + ' innerH=' + window.innerHeight);
                }, 3000);
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(consoleScript)

        let webView = KeyHandlingWebView(frame: .zero, configuration: configuration)
        webView.onKey = { [weak self] direction in
            self?.onUserPageTurn?()
            switch direction {
            case .forward: self?.pageForward()
            case .back: self?.pageBack()
            }
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.bounces = false
        self.webView = webView

        observeTypography()

        if let book = reader.book, let chapter = reader.chapter,
           let url = readerURL(bookID: book.id, chapterHref: chapter.jumpTarget) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    /// Drops the script message handler when the view leaves the hierarchy:
    /// `add` retains this bridge, which retains the webview, so without
    /// this every opened book would leak.
    func dismantle() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
        webView = nil
    }

    // MARK: Page driving (shared JS contract)

    static func javaScriptLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8)
        else { return "''" }
        return literal
    }

    func pageForward() {
        evaluate("readerScrollBy(1)")
    }

    func pageBack() {
        evaluate("readerScrollBy(-1)")
    }

    func jumpToChapter(_ target: String) {
        evaluate("readerDisplay(\(Self.javaScriptLiteral(target)))")
    }

    private func evaluate(_ script: String) {
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: Typography

    private func applyTypography() {
        let preferences = reader.preferences
        evaluate(
            "readerApplyTypography(\(preferences.fontSize),\(preferences.lineHeight),\(preferences.lineWidth))"
        )
    }

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

extension ReaderBridge: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url,
           url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // reader.js defines readerApplyTypography before its async open, so
        // this stores the current preferences for when the rendition appears.
        applyTypography()
        // Hardware-key page turns ride on the web view being first
        // responder (see `KeyHandlingWebView`).
        webView.becomeFirstResponder()
    }
}

extension ReaderBridge: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "reader", let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "console":
            // Page diagnostics: visible in the runtime log under the app pid.
            print("[reader-js][\(body["level"] ?? "")] \(body["text"] ?? "")")
        case "relocated":
            let page = (body["page"] as? NSNumber)?.intValue ?? 1
            let totalPages = (body["totalPages"] as? NSNumber)?.intValue ?? 0
            print("[reader-js] relocated: page \(page)/\(totalPages) href=\(body["href"] ?? "nil")")
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

extension ReaderBridge: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            UIApplication.shared.open(url)
        }
        return nil
    }
}
