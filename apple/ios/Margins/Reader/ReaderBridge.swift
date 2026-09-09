import SwiftUI
import UIKit
import WebKit
import OSLog
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
        if let direction = Self.pageDirection(for: presses) {
            onKey?(direction)
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Swallow the matching key-up without paging again: the turn
        // already happened in `pressesBegan`, and the web view must not
        // see the key either.
        if Self.pageDirection(for: presses) != nil { return }
        super.pressesEnded(presses, with: event)
    }

    private static func pageDirection(for presses: Set<UIPress>) -> PageDirection? {
        for press in presses {
            guard let key = press.key else { continue }
            switch key.keyCode {
            case .keyboardRightArrow, .keyboardDownArrow, .keyboardSpacebar:
                return .forward
            case .keyboardLeftArrow, .keyboardUpArrow:
                return .back
            default:
                break
            }
        }
        return nil
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
    var callbacks: ReaderCallbacks = ReaderCallbacks()

    func makeCoordinator() -> ReaderBridge {
        ReaderBridge(model: model, reader: reader)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = context.coordinator.makeWebView()
        // Hand the coordinator over on the next tick: writing state here
        // mutates SwiftUI state during view update, and SwiftUI silently
        // discards the write - the scene's `bridge` would stay nil for the
        // lifetime of the reader (chrome buttons and tap zones dead).
        Task { @MainActor in
            bridge = context.coordinator
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Keep the hooks current: the coordinator was created once, but
        // the scene's closures capture per-render state.
        context.coordinator.callbacks = callbacks
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: ReaderBridge) {
        coordinator.dismantle()
    }
}

/// Owns the reader webview and exposes page-turn/jump evaluation to the
/// scene (tap zones, swipes, hardware keys).
/// Scene-provided hooks, applied to the bridge on every render. Kept as
/// one struct so the representable takes a single parameter.
struct ReaderCallbacks {
    var userPageTurn: () -> Void = {}
    /// A plain tap on the reading surface, as fractions (0–1) of the
    /// reader view: the WKWebView swallows SwiftUI gestures, so the page
    /// reports taps itself (left third = back, right third = forward,
    /// middle = chrome).
    var pageTap: (Double, Double) -> Void = { _, _ in }
    /// A horizontal swipe on the page; `true` means forward.
    var pageSwipe: (Bool) -> Void = { _ in }
    /// The epub.js locations finished generating: the position slider can
    /// now scrub to an exact CFI.
    var locationsReady: () -> Void = {}
    var captureRequest: (ReaderBridge.ReaderSelection) -> Void = { _ in }
    var highlightRequest: (ReaderBridge.ReaderSelection) -> Void = { _ in }
}

@MainActor
final class ReaderBridge: NSObject {
    private let model: LibraryModel
    private let reader: ReaderModel
    private var webView: WKWebView?
    var callbacks = ReaderCallbacks()
    /// The latest completed text selection, for the edit-menu actions.
    private(set) var latestSelection: ReaderSelection?

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
            self?.callbacks.userPageTurn()
            switch direction {
            case .forward: self?.pageForward()
            case .back: self?.pageBack()
            }
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        // The epub.js stage handles all paging itself (transform-animated
        // columns); the native scroll view would only allow the outer
        // canvas to drift out of sync with the rendition's position. Its
        // pan recognizer must also go: it steals drags from SwiftUI
        // controls overlaying the web view (the position slider's drag
        // dies mid-gesture and commits the press-point value).
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.panGestureRecognizer.isEnabled = false
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

    /// Scrubs to a whole-book percentage (0–100) via the generated epub.js
    /// locations; the page no-ops until they are ready.
    func scrubToPercent(_ percent: Double) {
        evaluate("readerScrubToPercent(\(percent))")
    }

    private func evaluate(_ script: String) {
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: Capture support (selections, highlights)

    /// The reader page's latest text selection, if any.
    struct ReaderSelection {
        var cfiRange: String
        var text: String
    }

    /// Renders highlight overlays for mark CFI ranges; epub.js dedupes by
    /// range, so re-adding after chapter loads is safe.
    func restoreHighlights(_ cfiRanges: [String]) {
        for cfiRange in cfiRanges where !cfiRange.isEmpty {
            evaluate("readerHighlight(\(Self.javaScriptLiteral(cfiRange)))")
        }
    }

    /// Collapses the active selection after a capture commits.
    func clearSelection() {
        evaluate("readerClearSelection()")
    }

    /// The current page's CFI — tracked from `relocated` events rather
    /// than a JS round-trip, so it is valid the moment a page settles.
    private(set) var currentCfi: String?

    /// The current page's CFI, for page-anchored marks.
    func currentPageCfi() -> String? {
        currentCfi ?? latestSelection?.cfiRange
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
            // Also mirrored to the unified log — stdout is not captured for
            // simulator launches here, and these lines are the reader's
            // only failure signal.
            let text = "\(body["text"] ?? "")"
            Logger(subsystem: "io.github.nathanstefanik.margins", category: "reader-js").log("\(text, privacy: .public)")
            print("[reader-js][\(body["level"] ?? "")] \(text)")
        case "selected":
            if let cfiRange = body["cfiRange"] as? String,
               let text = body["text"] as? String,
               !cfiRange.isEmpty {
                latestSelection = ReaderSelection(cfiRange: cfiRange, text: text)
            }
        case "tap":
            let x = (body["x"] as? NSNumber)?.doubleValue ?? -1
            let y = (body["y"] as? NSNumber)?.doubleValue ?? -1
            callbacks.pageTap(x, y)
        case "swipe":
            callbacks.pageSwipe((body["forward"] as? NSNumber)?.boolValue == true)
        case "locations":
            callbacks.locationsReady()
        case "relocated":
            let page = (body["page"] as? NSNumber)?.intValue ?? 1
            let totalPages = (body["totalPages"] as? NSNumber)?.intValue ?? 0
            print("[reader-js] relocated: page \(page)/\(totalPages) href=\(body["href"] ?? "nil")")
            currentCfi = body["cfi"] as? String
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
    /// Extends the system text-selection callout with Note / Highlight.
    /// The page's `selected` event fires before this, so `latestSelection`
    /// holds the CFI range + text the actions act on.
    func webView(
        _ webView: WKWebView,
        editMenuForCharactersIn range: NSRange,
        recommendedActions: [UIMenuElement]
    ) -> [UIMenuElement]? {
        guard let selection = latestSelection else { return nil }
        let note = UIAction(title: "Note", image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in
            self?.callbacks.captureRequest(selection)
        }
        let highlight = UIAction(title: "Highlight", image: UIImage(systemName: "highlighter")) { [weak self] _ in
            self?.callbacks.highlightRequest(selection)
        }
        return [UIMenu(title: "", options: .displayInline, children: [note, highlight])] + recommendedActions
    }

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
