import WebKit

/// Weak proxy: WKUserContentController retains its handlers strongly, so
/// registering the controller directly would keep it (and its webview) alive
/// for the rest of the process.
@MainActor
final class ReaderMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var controller: ReaderController?

    init(controller: ReaderController) {
        self.controller = controller
        super.init()
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            self.controller?.didReceiveScriptMessage(message)
        }
    }
}
