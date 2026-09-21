#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
import MarginsModel

/// The committed reader-layout EPUBs (see Fixtures/reader-layout/README.md).
enum ReaderLayoutFixture: String, CaseIterable, Sendable {
    case reflowable
    case rtl
    case fixedLayout = "fixed-layout"

    var data: Data {
        get throws {
            guard let url = Bundle.module.url(
                forResource: rawValue,
                withExtension: "epub",
                subdirectory: "Fixtures/reader-layout"
            ) else {
                throw ReaderLayoutHarnessError.missingFixture(rawValue)
            }
            return try Data(contentsOf: url)
        }
    }
}

enum ReaderLayoutHarnessError: Error, CustomStringConvertible {
    case missingFixture(String)
    case timedOut(String)
    case javaScript(String)
    case readerOpenFailed(String)

    var description: String {
        switch self {
        case .missingFixture(let name): "missing fixture \(name).epub"
        case .timedOut(let what): "timed out waiting for \(what)"
        case .javaScript(let script): "javascript failed: \(script)"
        case .readerOpenFailed(let detail): "reader open failed: \(detail)"
        }
    }
}

/// Drives the real vendored reader page in an offscreen WKWebView, serving
/// the fixture EPUB through the production `ReaderSchemeHandler` and
/// collecting everything the page posts to the `reader` message handler.
///
/// macOS-only: the reader page is shared with iOS, but its WKWebView can
/// only be hosted by a macOS test process. Hosted in a transparent
/// NSWindow so navigation completes under `swift test`; rAF is still
/// shimmed. Cold WebKit startup *and* the first navigation are serialized
/// so two suites cannot spawn content processes at the same time.
///
/// All waits are async and bounded. The test harness cannot spin the run
/// loop synchronously: under `swift test`, the main dispatch queue — which
/// delivers WebKit's script results and message-handler callbacks — only
/// drains while the test is suspended.
@MainActor
final class ReaderLayoutHarness {
    private(set) var webView: WKWebView!
    private var window: NSWindow?
    private var relay: MessageRelay?
    private let fixtureData: Data
    private var viewport: CGSize
    private var messages: [[String: Any]] = []
    private var consoleLines: [String] = []
    private var pageDidFinish = false
    private var navigationError: String?

    private static let pollInterval = Duration.milliseconds(20)
    private static var installing = false

    init(fixture: ReaderLayoutFixture, viewport: CGSize) throws {
        fixtureData = try fixture.data
        self.viewport = viewport
    }

    func dismantle() {
        webView?.navigationDelegate = nil
        webView?.loadHTMLString("", baseURL: nil)
        window?.contentView = nil
        window?.close()
        window = nil
        webView = nil
        relay = nil
    }

    /// Loads the reader page and applies the app's default macOS typography
    /// (`ReaderPreferences.defaultFontSize` / default line height / default
    /// line width), matching what `ReaderController` does. Pass
    /// `platform: nil` to exercise the iOS page (no desktop policy).
    func load(
        bookID: String = "fixture",
        chapter: String = "ch1.xhtml",
        platform: String? = "macos",
        typography: (fontSize: Double, lineHeight: Double, lineWidth: Double, unit: String)? = (110, 1.6, 72, "%")
    ) async throws {
        // Hold the process-wide gate through first navigation: the matrix
        // and integration suites otherwise spawn two WKWebViews at once,
        // and under CI the first load can sit until the 30s timeout with
        // an empty console.
        while Self.installing {
            try await Task.sleep(for: Self.pollInterval)
        }
        Self.installing = true
        defer { Self.installing = false }

        var components = URLComponents()
        components.scheme = "margins-reader"
        components.host = "app"
        components.path = "/reader.html"
        var queryItems = [
            URLQueryItem(name: "book", value: bookID),
            URLQueryItem(name: "chapter", value: chapter),
        ]
        if let platform {
            queryItems.append(URLQueryItem(name: "platform", value: platform))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw ReaderLayoutHarnessError.readerOpenFailed("bad reader URL")
        }
        try await installWebView()
        do {
            try await navigate(to: url)
        } catch let error as ReaderLayoutHarnessError {
            guard case .timedOut = error else { throw error }
            dismantle()
            try await installWebView()
            try await navigate(to: url)
        }

        guard let typography else { return }
        try await evaluate(
            "readerApplyTypography(\(typography.fontSize),\(typography.lineHeight),\(typography.lineWidth),"
                + "'\(typography.unit)')"
        )
    }

    /// Sets the viewport without waiting; for drag-like burst tests.
    func setViewport(width: Double, height: Double) {
        viewport = CGSize(width: width, height: height)
        let size = NSSize(width: width, height: height)
        webView?.setFrameSize(size)
        window?.setContentSize(size)
    }

    private func navigate(to url: URL) async throws {
        pageDidFinish = false
        navigationError = nil
        webView.load(URLRequest(url: url))
        try await waitForNavigation()
    }

    private func installWebView() async throws {
        if webView != nil { return }

        let app = NSApplication.shared
        if app.activationPolicy() == .prohibited {
            app.setActivationPolicy(.accessory)
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(
            ReaderSchemeHandler(bytesProvider: { [fixtureData] _ in fixtureData }),
            forURLScheme: "margins-reader"
        )
        // Test-only diagnostics: console + uncaught errors are invisible
        // from Swift otherwise, and a silently stalled reader would look
        // like an empty message list.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.diagnosticScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        let relay = MessageRelay(harness: self)
        configuration.userContentController.add(relay, name: "reader")
        let frame = NSRect(origin: .zero, size: viewport)
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.navigationDelegate = relay
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = webView
        window.orderFront(nil)
        self.relay = relay
        self.window = window
        self.webView = webView
    }

    private func waitForNavigation() async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let navigationError {
                throw ReaderLayoutHarnessError.readerOpenFailed(navigationError)
            }
            if pageDidFinish { return }
            try await Task.sleep(for: Self.pollInterval)
        }
        throw ReaderLayoutHarnessError.timedOut(
            "reader.html to load (console: \(consoleLines.suffix(8)))"
        )
    }

    /// Waits until the page has no pending layout work, epub.js's queue has
    /// drained, and the visible text stopped changing.
    func waitForLayoutSettled(timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSet: [String]?
        var stable = 0
        while Date() < deadline {
            let settling = try? await pageLayoutState().settling
            let depth = try? await evaluate(
                "readerRendition && readerRendition.q ? readerRendition.q._q.length : -1"
            ) as? Int
            let current = (try? await visibleParagraphIDs()) ?? []
            if settling == false, depth == 0, current == lastSet {
                stable += 1
                if stable >= 2 {
                    return
                }
            } else {
                stable = 0
            }
            lastSet = current
            try await Task.sleep(for: Self.pollInterval)
        }
    }

    /// Number of section iframes currently visible on the reading surface.
    func visibleIframeCount() async throws -> Int {
        (try await evaluate("window.__marginsTest.visibleIframeCount()")) as? Int ?? -1
    }

    /// Resizes the reading viewport (the WKWebView frame) and waits for the
    /// page to settle on new measured geometry.
    func resize(to size: CGSize, timeout: TimeInterval = 10) async throws {
        setViewport(width: size.width, height: size.height)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = try? await geometry()
            if let current, abs(current.innerWidth - size.width) < 1, current.viewerWidth > 0 {
                return
            }
            try await Task.sleep(for: Self.pollInterval)
        }
        throw ReaderLayoutHarnessError.timedOut("viewport resize to \(size)")
    }

    /// Waits for a message of `type` matching `predicate`.
    func waitForMessage(
        _ type: String,
        timeout: TimeInterval = 30,
        matching predicate: (([String: Any]) -> Bool)? = nil,
        _ what: String
    ) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let message = messages.last(where: {
                $0["type"] as? String == type && (predicate?($0) ?? true)
            }) {
                return message
            }
            if let failure = readerFailure() {
                throw ReaderLayoutHarnessError.readerOpenFailed(failure)
            }
            try await Task.sleep(for: Self.pollInterval)
        }
        throw ReaderLayoutHarnessError.timedOut("\(what) (console: \(consoleLines.suffix(8)))")
    }

    /// Waits for relocation number `count + 1` (one-based ordering).
    func waitForRelocation(after count: Int, timeout: TimeInterval = 30) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if messages.filter({ $0["type"] as? String == "relocated" }).count > count,
               let last = messages.last(where: { $0["type"] as? String == "relocated" }) {
                return last
            }
            if let failure = readerFailure() {
                throw ReaderLayoutHarnessError.readerOpenFailed(failure)
            }
            try await Task.sleep(for: Self.pollInterval)
        }
        throw ReaderLayoutHarnessError.timedOut("relocation #\(count + 1)")
    }

    var relocationCount: Int {
        messages.filter { $0["type"] as? String == "relocated" }.count
    }

    func messageCount(of type: String) -> Int {
        messages.filter { $0["type"] as? String == type }.count
    }

    /// Waits for the latest relocation to describe a different location than
    /// `previous`. The page reports relocation from both the `rendered`
    /// hook and the `relocated` event, so a fixed count is not a settle
    /// signal — a changed fingerprint is.
    func waitForRelocationChange(
        from previous: [String: Any]?,
        timeout: TimeInterval = 30
    ) async throws -> [String: Any] {
        let previousFingerprint = previous.map(Self.relocationFingerprint)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let latest = lastRelocation,
               Self.relocationFingerprint(latest) != previousFingerprint {
                return latest
            }
            if let failure = readerFailure() {
                throw ReaderLayoutHarnessError.readerOpenFailed(failure)
            }
            try await Task.sleep(for: Self.pollInterval)
        }
        throw ReaderLayoutHarnessError.timedOut("a relocation change")
    }

    /// A relocation change means the *location* moved. Page totals can
    /// change from a reflow at the same CFI and must not read as a page
    /// turn.
    static func relocationFingerprint(_ relocation: [String: Any]) -> String {
        "\(relocation["cfi"] ?? "-")"
    }

    /// The latest relocated payload.
    var lastRelocation: [String: Any]? {
        messages.last(where: { $0["type"] as? String == "relocated" })
    }

    /// A reader failure posted through the page's error path, if any.
    func readerFailure() -> String? {
        consoleLines.last(where: { $0.contains("readerOpen failed:") })
    }

    /// Recent console output; used by diagnostics when a wait times out.
    func consoleTail(_ count: Int = 20) -> [String] {
        Array(consoleLines.suffix(count))
    }

    func evaluate(_ script: String, timeout: TimeInterval = 15) async throws -> Any? {
        nonisolated(unsafe) var outcome: Result<Any?, Error>?
        webView.evaluateJavaScript(script) { value, error in
            if let error {
                outcome = .failure(error)
            } else {
                outcome = .success(value)
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let outcome {
                return try outcome.get()
            }
            try await Task.sleep(for: Self.pollInterval)
        }
        throw ReaderLayoutHarnessError.timedOut("evaluate: \(script.prefix(120))")
    }

    /// Evaluates a script that resolves to JSON and decodes it.
    func evaluateJSON(_ script: String, timeout: TimeInterval = 15) async throws -> Any {
        let wrapped = "(function(){ return JSON.stringify(\(script)); })()"
        guard let raw = try await evaluate(wrapped, timeout: timeout) as? String,
              let data = raw.data(using: .utf8)
        else {
            throw ReaderLayoutHarnessError.javaScript(script)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    func visibleParagraphIDs() async throws -> [String] {
        let result = try await evaluate("window.__marginsTest.visibleParagraphIDs()")
        return (result as? [String]) ?? []
    }

    /// A visible paragraph's rect in outer-window coordinates.
    struct ParagraphRect: Decodable {
        var id: String
        var left: Double
        var right: Double
        var width: Double
        var top: Double
        var bottom: Double
    }

    func visibleParagraphRects() async throws -> [ParagraphRect] {
        guard let json = try await evaluateJSON("window.__marginsTest.visibleParagraphRects()") as? [[String: Any]] else {
            throw ReaderLayoutHarnessError.javaScript("visibleParagraphRects")
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode([ParagraphRect].self, from: data)
    }

    /// Waits for the visible paragraph set to differ from `previous`.
    /// Geometry — not a relocation message — is the settle signal, because
    /// the page reports relocation from the `rendered` hook before the view
    /// swap is on screen.
    func waitForVisibleParagraphChange(
        from previous: [String],
        timeout: TimeInterval = 5
    ) async throws -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let current = try? await visibleParagraphIDs(), current != previous {
                return current
            }
            try await Task.sleep(for: Self.pollInterval)
        }
        throw ReaderLayoutHarnessError.timedOut("visible paragraphs to change")
    }

    /// Waits until epub.js's rendition queue has drained and the visible
    /// text has stopped changing, so a test can issue the next command
    /// without racing queued page turns.
    func waitForReaderIdle(timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSet: [String]?
        var stableCount = 0
        while Date() < deadline {
            let depth = try? await evaluate(
                "readerRendition && readerRendition.q ? readerRendition.q._q.length : -1"
            ) as? Int
            let current = (try? await visibleParagraphIDs()) ?? []
            if depth == 0, current == lastSet {
                stableCount += 1
                if stableCount >= 2 {
                    return
                }
            } else {
                stableCount = 0
            }
            lastSet = current
            try await Task.sleep(for: Self.pollInterval)
        }
    }

    func waitForVisibleParagraph(_ id: String, timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let ids = try? await visibleParagraphIDs(), ids.contains(id) {
                return
            }
            try await Task.sleep(for: Self.pollInterval)
        }
        throw ReaderLayoutHarnessError.timedOut("paragraph \(id) to become visible")
    }

    /// Outer `#viewer` and rendition geometry, in CSS px.
    struct Geometry: Decodable {
        var innerWidth: Double
        var innerHeight: Double
        var pageWidth: Double
        var viewerWidth: Double
        var viewerHeight: Double
        var viewerPaddingLeft: Double
        var stageWidth: Double
        var stageHeight: Double
        var columnWidth: Double
        var gap: Double
        var renderedDivisor: Int
        var iframeCount: Int
    }

    /// Waits for the rendition to report `divisor` columns.
    func waitForDivisor(_ divisor: Int, timeout: TimeInterval = 10) async throws -> Geometry {
        let deadline = Date().addingTimeInterval(timeout)
        var latest: Geometry?
        while Date() < deadline {
            let current = try? await geometry()
            if let current {
                latest = current
                if current.renderedDivisor == divisor {
                    return current
                }
            }
            try await Task.sleep(for: Self.pollInterval)
        }
        throw ReaderLayoutHarnessError.timedOut(
            "divisor \(divisor) (last: \(latest.map { "divisor=\($0.renderedDivisor) viewer=\($0.viewerWidth) stage=\($0.stageWidth)" } ?? "none"))"
        )
    }

    func geometry() async throws -> Geometry {
        guard let json = try await evaluateJSON("window.__marginsTest.geometry()") as? [String: Any] else {
            throw ReaderLayoutHarnessError.javaScript("geometry")
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(Geometry.self, from: data)
    }

    /// The page's `readerPageLayoutState()`: requested vs effective mode,
    /// last applied geometry, and the measured glyph width.
    struct PageLayoutState: Decodable {
        struct Applied: Decodable {
            var mode: String
            var pages: Int
            var viewerWidthPx: Double
            var insetX: Double
        }

        var requested: String
        var effective: String
        var applied: Applied?
        var previousPages: Int
        var glyphWidthPx: Double
        var desktop: Bool
        /// True while a layout transaction or debounced relayout is pending.
        var settling: Bool
    }

    func pageLayoutState() async throws -> PageLayoutState {
        guard let json = try await evaluateJSON("window.readerPageLayoutState()") as? [String: Any] else {
            throw ReaderLayoutHarnessError.javaScript("pageLayoutState")
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(PageLayoutState.self, from: data)
    }

    fileprivate func record(_ body: [String: Any]) {
        if body["type"] as? String == "console" {
            consoleLines.append("\(body["level"] ?? "") \(body["text"] ?? "")")
            return
        }
        messages.append(body)
    }

    /// `WKScriptMessageHandler` must be an Objective-C object; the harness
    /// itself is not one, so a tiny relay forwards into it.
    private final class MessageRelay: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private weak var harness: ReaderLayoutHarness?

        init(harness: ReaderLayoutHarness) {
            self.harness = harness
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "reader", let body = message.body as? [String: Any] else { return }
            MainActor.assumeIsolated {
                harness?.record(body)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                harness?.pageDidFinish = true
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            MainActor.assumeIsolated {
                harness?.navigationError = error.localizedDescription
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            MainActor.assumeIsolated {
                harness?.navigationError = error.localizedDescription
            }
        }
    }

    /// Test-only helpers evaluated inside the page. Kept out of the vendored
    /// reader so production has no test hooks.
    ///
    /// The diagnostic script also replaces `requestAnimationFrame` with a
    /// timer-backed shim *before* epub.js loads: WebKit fully suspends rAF
    /// in a hidden page, and epub.js routes its rendition queue, relayout
    /// and relocation reporting through it. In the app the reader is on
    /// screen; in the test process it cannot be, so the shim keeps the
    /// engine's event loop turning deterministically.
    private static let diagnosticScript = """
    (function() {
      (function() {
        var shimmed = function(callback) {
          return setTimeout(function() { callback(performance.now()); }, 16);
        };
        window.requestAnimationFrame = shimmed;
        window.cancelAnimationFrame = function(id) { clearTimeout(id); };
      })();
      var send = function(level, text) {
        try { window.webkit.messageHandlers.reader.postMessage({ type: 'console', level: level, text: text }); } catch (e) {}
      };
      var forward = function(level) {
        var original = console[level];
        console[level] = function() {
          send(level, Array.prototype.join.call(arguments, ' '));
          original.apply(console, arguments);
        };
      };
      forward('log');
      forward('error');
      window.onerror = function(msg, src, line, col) { send('onerror', msg + ' @' + src + ':' + line + ':' + col); };
      window.addEventListener('unhandledrejection', function(event) {
        send('unhandledrejection', String(event.reason));
      });
      window.__marginsTest = {
        geometry: function() {
          var viewer = document.getElementById('viewer');
          var page = document.getElementById('page');
          var rect = viewer ? viewer.getBoundingClientRect() : { width: 0, height: 0 };
          var pageRect = page ? page.getBoundingClientRect() : { width: 0, height: 0 };
          var style = viewer ? window.getComputedStyle(viewer) : null;
          // `readerRendition` is reader.js's top-level binding; classic
          // scripts share the global lexical scope.
          var rendition = typeof readerRendition === 'undefined' ? null : readerRendition;
          var manager = rendition && rendition.manager;
          var layout = manager && manager.layout;
          var iframes = document.querySelectorAll('iframe');
          return {
            innerWidth: window.innerWidth,
            innerHeight: window.innerHeight,
            pageWidth: pageRect.width,
            viewerWidth: rect.width,
            viewerHeight: rect.height,
            viewerPaddingLeft: style ? parseFloat(style.paddingLeft) : 0,
            stageWidth: layout ? layout.width : 0,
            stageHeight: layout ? layout.height : 0,
            columnWidth: layout ? layout.columnWidth : 0,
            gap: layout ? layout.gap : 0,
            renderedDivisor: layout ? layout.divisor : 0,
            iframeCount: iframes.length
          };
        },
        visibleParagraphRects: function() {
          var rects = [];
          // Clip to the reading frame the way the eye does: the viewer's
          // padding box, not the window. A section iframe is several pages
          // wide and scrolled inside the stage, so off-page columns keep
          // valid window coordinates.
          var viewer = document.getElementById('viewer');
          var view = viewer ? viewer.getBoundingClientRect() : { left: 0, top: 0, right: window.innerWidth, bottom: window.innerHeight };
          var viewerStyle = viewer ? window.getComputedStyle(viewer) : null;
          var clipLeft = view.left + (viewerStyle ? parseFloat(viewerStyle.paddingLeft) : 0);
          var clipRight = view.right - (viewerStyle ? parseFloat(viewerStyle.paddingRight) : 0);
          var clipTop = view.top + (viewerStyle ? parseFloat(viewerStyle.paddingTop) : 0);
          var clipBottom = view.bottom - (viewerStyle ? parseFloat(viewerStyle.paddingBottom) : 0);
          var frames = document.querySelectorAll('iframe');
          for (var f = 0; f < frames.length; f++) {
            var frame = frames[f];
            var frameRect = frame.getBoundingClientRect();
            // epub.js hides inactive views with `visibility: hidden`, which
            // keeps their geometry; skip them explicitly.
            if (frameRect.width <= 0 || frameRect.height <= 0) { continue; }
            if (window.getComputedStyle(frame).visibility === 'hidden') { continue; }
            var doc = null;
            try { doc = frame.contentDocument; } catch (e) { continue; }
            if (!doc) { continue; }
            var paragraphs = doc.querySelectorAll('p[id]');
            for (var p = 0; p < paragraphs.length; p++) {
              // A paragraph split across a column boundary has a union
              // element box spanning both columns; use the text fragment
              // boxes so a paragraph reads as the part actually on this
              // page.
              var range = doc.createRange();
              range.selectNodeContents(paragraphs[p]);
              var boxes = Array.prototype.slice.call(range.getClientRects());
              if (!boxes.length) {
                var elementRect = paragraphs[p].getBoundingClientRect();
                boxes = [{ left: elementRect.left, top: elementRect.top, width: elementRect.width, height: elementRect.height }];
              }
              var union = null;
              for (var b = 0; b < boxes.length; b++) {
                var box = boxes[b];
                var left = frameRect.left + box.left;
                var right = left + box.width;
                var top = frameRect.top + box.top;
                var bottom = top + box.height;
                if (right <= clipLeft || left >= clipRight || bottom <= clipTop || top >= clipBottom) {
                  continue;
                }
                union = union
                  ? {
                      left: Math.min(union.left, left),
                      right: Math.max(union.right, right),
                      top: Math.min(union.top, top),
                      bottom: Math.max(union.bottom, bottom)
                    }
                  : { left: left, right: right, top: top, bottom: bottom };
              }
              if (union) {
                rects.push({
                  id: paragraphs[p].id,
                  left: union.left,
                  right: union.right,
                  width: union.right - union.left,
                  top: union.top,
                  bottom: union.bottom
                });
              }
            }
          }
          return rects;
        },
        visibleParagraphIDs: function() {
          return window.__marginsTest.visibleParagraphRects().map(function(r) { return r.id; });
        },
        visibleIframeCount: function() {
          var count = 0;
          var frames = document.querySelectorAll('iframe');
          for (var f = 0; f < frames.length; f++) {
            var rect = frames[f].getBoundingClientRect();
            if (rect.width <= 0 || rect.height <= 0) { continue; }
            if (window.getComputedStyle(frames[f]).visibility === 'hidden') { continue; }
            count += 1;
          }
          return count;
        }
      };
    })();
    """
}
#endif
