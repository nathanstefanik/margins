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
/// only be hosted by a macOS test process.
///
/// All waits are async and bounded. The test harness cannot spin the run
/// loop synchronously: under `swift test`, the main dispatch queue — which
/// delivers WebKit's script results and message-handler callbacks — only
/// drains while the test is suspended.
@MainActor
final class ReaderLayoutHarness {
    let webView: WKWebView
    private var messages: [[String: Any]] = []
    private var consoleLines: [String] = []

    private static let pollInterval = Duration.milliseconds(20)

    init(fixture: ReaderLayoutFixture, viewport: CGSize) throws {
        let data = try fixture.data
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(
            ReaderSchemeHandler(bytesProvider: { _ in data }),
            forURLScheme: "margins-reader"
        )
        // Test-only diagnostics: console + uncaught errors are invisible
        // from Swift otherwise, and a silently stalled reader would look
        // like an empty message list.
        let diagnostics = WKUserScript(
            source: Self.diagnosticScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(diagnostics)
        webView = WKWebView(
            frame: NSRect(origin: .zero, size: viewport),
            configuration: configuration
        )
        configuration.userContentController.add(MessageRelay(harness: self), name: "reader")
    }

    private var window: NSWindow?

    /// WebKit suspends `requestAnimationFrame` (and throttles timers) while
    /// the page is hidden, and epub.js drives its whole rendition queue
    /// through rAF. The page therefore needs an on-screen window; this is
    /// the closest a test process gets to the app's visible reader.
    /// Returns false when the process has no window server session.
    @discardableResult
    func attachWindow() -> Bool {
        guard window == nil else { return true }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: webView.frame.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.window = window
        return true
    }

    func dismantle() {
        window?.orderOut(nil)
        window = nil
        webView.loadHTMLString("", baseURL: nil)
    }

    /// Loads the reader page and applies the app's default macOS typography
    /// (`ReaderPreferences.defaultFontSize` / default line height / default
    /// line width), matching what `ReaderController.didFinish` does.
    func load(
        bookID: String = "fixture",
        chapter: String = "ch1.xhtml",
        typography: (fontSize: Double, lineHeight: Double, lineWidth: Double)? = (110, 1.6, 72)
    ) async throws {
        var components = URLComponents()
        components.scheme = "margins-reader"
        components.host = "app"
        components.path = "/reader.html"
        components.queryItems = [
            URLQueryItem(name: "book", value: bookID),
            URLQueryItem(name: "chapter", value: chapter),
        ]
        guard let url = components.url else {
            throw ReaderLayoutHarnessError.readerOpenFailed("bad reader URL")
        }
        webView.load(URLRequest(url: url))

        guard let typography else { return }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let ready = try? await evaluate(
                "typeof readerApplyTypography === 'function'", timeout: 2
            ) as? Bool, ready {
                try await evaluate(
                    "readerApplyTypography(\(typography.fontSize),\(typography.lineHeight),\(typography.lineWidth))"
                )
                return
            }
            try await Task.sleep(for: Self.pollInterval)
        }
        throw ReaderLayoutHarnessError.timedOut("reader.js to define readerApplyTypography")
    }

    /// Waits for a message of `type` matching `predicate`.
    func waitForMessage(
        _ type: String,
        timeout: TimeInterval = 15,
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
    func waitForRelocation(after count: Int, timeout: TimeInterval = 15) async throws -> [String: Any] {
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

    /// Waits for the latest relocation to describe a different location than
    /// `previous`. The page reports relocation from both the `rendered`
    /// hook and the `relocated` event, so a fixed count is not a settle
    /// signal — a changed fingerprint is.
    func waitForRelocationChange(
        from previous: [String: Any]?,
        timeout: TimeInterval = 15
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
        var viewerWidth: Double
        var viewerHeight: Double
        var stageWidth: Double
        var stageHeight: Double
        var renderedDivisor: Int
        var iframeCount: Int
    }

    func geometry() async throws -> Geometry {
        guard let json = try await evaluateJSON("window.__marginsTest.geometry()") as? [String: Any] else {
            throw ReaderLayoutHarnessError.javaScript("geometry")
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(Geometry.self, from: data)
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
    private final class MessageRelay: NSObject, WKScriptMessageHandler {
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
          var rect = viewer ? viewer.getBoundingClientRect() : { width: 0, height: 0 };
          // `readerRendition` is reader.js's top-level binding; classic
          // scripts share the global lexical scope.
          var rendition = typeof readerRendition === 'undefined' ? null : readerRendition;
          var manager = rendition && rendition.manager;
          var layout = manager && manager.layout;
          var iframes = document.querySelectorAll('iframe');
          return {
            innerWidth: window.innerWidth,
            innerHeight: window.innerHeight,
            viewerWidth: rect.width,
            viewerHeight: rect.height,
            stageWidth: layout ? layout.width : 0,
            stageHeight: layout ? layout.height : 0,
            renderedDivisor: layout ? layout.divisor : 0,
            iframeCount: iframes.length
          };
        },
        visibleParagraphIDs: function() {
          var ids = [];
          var frames = document.querySelectorAll('iframe');
          for (var f = 0; f < frames.length; f++) {
            var frame = frames[f];
            var frameRect = frame.getBoundingClientRect();
            var doc = null;
            try { doc = frame.contentDocument; } catch (e) { continue; }
            if (!doc) { continue; }
            var paragraphs = doc.querySelectorAll('p[id]');
            for (var p = 0; p < paragraphs.length; p++) {
              var rect = paragraphs[p].getBoundingClientRect();
              var left = frameRect.left + rect.left;
              var top = frameRect.top + rect.top;
              if (left + rect.width > 0 && left < window.innerWidth && top + rect.height > 0 && top < window.innerHeight) {
                ids.push(paragraphs[p].id);
              }
            }
          }
          return ids;
        }
      };
    })();
    """
}
#endif
