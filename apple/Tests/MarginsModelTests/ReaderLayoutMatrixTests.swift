#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import Testing
import WebKit
import MarginsModel

/// Acceptance matrix for the desktop layout: window-sized viewports, text
/// sizes, line widths, and themes. The expected page counts come from the
/// policy constants (see docs/testing/macos-reader-layout.md); the
/// no-clipping and non-blank checks are the readability guardrails.
///
/// Screenshots are captured only when `MARGINS_LAYOUT_SNAPSHOTS=1` is set
/// (they land in `/tmp/margins-matrix-*.png`) so CI stays headless.
@Suite("Reader layout matrix", .serialized)
@MainActor
struct ReaderLayoutMatrixTests {
    struct Scenario {
        var name: String
        var width: Double
        var height: Double
        var fontSize: Double = 110
        var lineHeight: Double = 1.6
        var lineWidth: Double = 72
        var theme: String?
        var expectedPages: Int
    }

    @Test("the desktop layout matrix holds")
    func matrix() async throws {
        let scenarios: [Scenario] = [
            // 15-inch MacBook Air at its widest supported scaling
            // (1920 x 1243 points; window less title bar and footer).
            Scenario(name: "fullscreen-default", width: 1920, height: 1123, expectedPages: 2),
            Scenario(name: "normal-default", width: 1100, height: 800, expectedPages: 1),
            Scenario(name: "half-screen", width: 720, height: 800, expectedPages: 1),
            Scenario(name: "notes-open-window", width: 740, height: 800, expectedPages: 1),
            Scenario(name: "large-text-200", width: 1100, height: 800, fontSize: 200, expectedPages: 1),
            Scenario(name: "small-text-70", width: 1100, height: 800, fontSize: 70, expectedPages: 2),
            Scenario(name: "narrow-measure-50ch", width: 1100, height: 800, lineWidth: 50, expectedPages: 1),
            Scenario(name: "wide-measure-110ch", width: 1100, height: 800, lineWidth: 110, expectedPages: 1),
            Scenario(name: "low-window", width: 1100, height: 500, expectedPages: 1),
            Scenario(name: "dark-fullscreen", width: 1920, height: 1123, theme: "dark", expectedPages: 2),
        ]
        let captureSnapshots = ProcessInfo.processInfo.environment["MARGINS_LAYOUT_SNAPSHOTS"] == "1"

        for scenario in scenarios {
            let harness = try ReaderLayoutHarness(
                fixture: .reflowable,
                viewport: CGSize(width: scenario.width, height: scenario.height)
            )
            defer { harness.dismantle() }
            try await harness.load()
            _ = try await harness.waitForRelocation(after: 0)
            if let theme = scenario.theme {
                try await harness.evaluate("readerSetTheme('\(theme)')")
            }
            try await harness.evaluate(
                "readerApplyTypography(\(scenario.fontSize),\(scenario.lineHeight),\(scenario.lineWidth),'%')"
            )
            try await harness.waitForLayoutSettled()
            try await Task.sleep(for: .milliseconds(300))

            let state = try await harness.pageLayoutState()
            let geometry = try await harness.geometry()
            let rects = try await harness.visibleParagraphRects()
            let clipLeft = geometry.viewerPaddingLeft
            let clipRight = geometry.innerWidth - geometry.viewerPaddingLeft

            #expect(state.applied?.pages == scenario.expectedPages, "\(scenario.name): pages")
            // Nothing on screen may overflow the reading surface, and a
            // settled page is never blank.
            #expect(
                rects.allSatisfy { $0.right <= clipRight + 4 && $0.left >= clipLeft - 4 },
                "\(scenario.name): clipped paragraph"
            )
            #expect(rects.isEmpty == false, "\(scenario.name): blank page")

            if captureSnapshots {
                let configuration = WKSnapshotConfiguration()
                configuration.rect = harness.webView.bounds
                let image = try await harness.webView.takeSnapshot(configuration: configuration)
                if let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try png.write(
                        to: URL(fileURLWithPath: "/tmp/margins-matrix-\(scenario.name).png")
                    )
                }
            }
        }
    }
}
#endif
