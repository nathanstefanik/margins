import SwiftUI
import WebKit
import MarginsModel

struct ReaderWebView: NSViewRepresentable {
    let model: LibraryModel
    let reader: ReaderModel

    func makeCoordinator() -> ReaderController {
        ReaderController(model: model, reader: reader)
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // The webview is created once; chapter changes are pushed into it
        // by the coordinator itself.
    }
}
