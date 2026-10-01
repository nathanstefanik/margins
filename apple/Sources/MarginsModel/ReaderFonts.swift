import CoreText
import Foundation

/// Registers the reader's bundled fonts with Core Text so native chrome
/// can render them by family name. The webview does not need this — it
/// loads the same files over `margins-reader://` via `@font-face` — but
/// SwiftUI `Font.custom` does. iOS calls this once at launch; macOS has no
/// native use for the bundled face.
public enum ReaderFonts {
    /// The bundled faces, as flat names inside the reader resources.
    private static let bundledFonts = [
        "AtkinsonHyperlegibleNext",
        "AtkinsonHyperlegibleNext-Italic",
    ]

    /// Registers the bundled faces for this process. Idempotent — Core
    /// Text ignores fonts that are already registered.
    public static func registerBundled() {
        for name in bundledFonts {
            guard
                let url = Bundle.module.url(
                    forResource: name,
                    withExtension: "ttf",
                    subdirectory: "reader"
                )
            else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
