import CoreGraphics
import Foundation
import ImageIO
import MarginsModel
import Testing

@Suite("Cover placeholder and tint")
struct CoverTintTests {
    /// A flat 4×4 PNG at the given sRGB triple.
    private func writeSolidPNG(
        _ red: UInt8, _ green: UInt8, _ blue: UInt8, to path: String
    ) throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: 4, height: 4,
                bitsPerComponent: 8, bytesPerRow: 16,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(
            red: CGFloat(red) / 255, green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test("a flat cover averages to its own colour")
    func flatCoverAverage() throws {
        let path = NSTemporaryDirectory() + "covertint-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try writeSolidPNG(200, 80, 40, to: path)

        let rgb = try #require(CoverTint.average(ofImageAt: path))
        #expect(abs(rgb.red - 200) <= 2)
        #expect(abs(rgb.green - 80) <= 2)
        #expect(abs(rgb.blue - 40) <= 2)

        // Cached: a second read returns the same triple.
        #expect(CoverTint.average(ofImageAt: path) == rgb)
    }

    @Test("a missing cover has no tint")
    func missingCover() {
        let missing = NSTemporaryDirectory() + "covertint-none-\(UUID().uuidString).png"
        #expect(CoverTint.average(ofImageAt: missing) == nil)
    }

    @Test("softened desaturates and clamps to the mid band")
    func softenedTint() {
        // A near-black cover: softened lands mid-dark, not black.
        let dark = CoverTint.softened(.init(10, 10, 12))
        #expect(dark.red > 60)
        // A saturated cover loses half its chroma but keeps its hue.
        let warm = CoverTint.softened(.init(230, 60, 30))
        #expect(warm.red > warm.green)
        #expect(warm.red > warm.blue)
        // A white cover doesn't burn to glare.
        let pale = CoverTint.softened(.init(250, 250, 250))
        #expect(pale.red < 220)
    }

    @Test("paper choice is stable per title and every paper is reachable")
    func paperStability() {
        let karamazov = BookCoverPlaceholder.paper(for: "The Brothers Karamazov")
        #expect(karamazov == BookCoverPlaceholder.paper(for: "The Brothers Karamazov"))
        #expect(karamazov != BookCoverPlaceholder.paper(for: "The Brothers Karamazov."))

        // Enumerate titles until every paper has been seen — they are
        // the same titles every run, so reachability is deterministic.
        var seen = Set<Int>()
        for i in 0..<64 {
            seen.insert(
                BookCoverPlaceholder.tintIndex(
                    for: "Shelf Book \(i)", paletteSize: BookCoverPlaceholder.papers.count))
        }
        #expect(seen.count == BookCoverPlaceholder.papers.count)
    }
}
