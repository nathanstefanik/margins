import CoreImage
import Foundation

/// The average colour of a book's real cover, for the detail header's
/// soft tint. ImageIO + CoreImage only — the apps turn the RGB into a
/// `Color` and their own gradient. Results are cached per path and
/// invalidated when the file's modification date moves.
public enum CoverTint {
    /// The average of the whole image as an sRGB 0–255 triple; nil when
    /// the path is unreadable or yields no renderable pixels. Safe from
    /// any actor — callers should dispatch off the main thread.
    public static func average(ofImageAt path: String) -> ReaderPalette.RGB? {
        let modificationDate =
            (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
            as? Date
        if let cached = cacheHit(path: path, modified: modificationDate) {
            return cached
        }
        guard let image = CIImage(contentsOf: URL(fileURLWithPath: path)),
            !image.extent.isEmpty
        else {
            return nil
        }
        // CIAreaAverage squeezes the whole extent into a single pixel.
        let extent = image.extent
        guard let area = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: extent),
        ])?.outputImage else { return nil }
        var bitmap = [UInt8](repeating: 0, count: 4)
        // One context for all renders — safe for concurrent use.
        context.render(
            area,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        let rgb = ReaderPalette.RGB(Int(bitmap[0]), Int(bitmap[1]), Int(bitmap[2]))
        store(path: path, modified: modificationDate, rgb: rgb)
        return rgb
    }

    /// A gentler version of a cover colour for a header tint: saturation
    /// pulled halfway toward the luminance, then luminance clamped into a
    /// mid band so neither a black nor a white cover glares.
    public static func softened(_ rgb: ReaderPalette.RGB) -> ReaderPalette.RGB {
        var r = Double(rgb.red) / 255
        var g = Double(rgb.green) / 255
        var b = Double(rgb.blue) / 255
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        r += (luma - r) * 0.5
        g += (luma - g) * 0.5
        b += (luma - b) * 0.5
        let soft = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let target = min(max(soft, 0.35), 0.78)
        if soft > 0.001 {
            let scale = target / soft
            r = min(r * scale, 1)
            g = min(g * scale, 1)
            b = min(b * scale, 1)
        }
        return ReaderPalette.RGB(
            Int((r * 255).rounded()),
            Int((g * 255).rounded()),
            Int((b * 255).rounded()))
    }

    private struct Entry {
        var modified: Date?
        var rgb: ReaderPalette.RGB
    }

    /// CIContext is safe for concurrent rendering — share one.
    private static let context = CIContext()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Entry] = [:]

    private static func cacheHit(path: String, modified: Date?) -> ReaderPalette.RGB? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[path], entry.modified == modified else { return nil }
        return entry.rgb
    }

    private static func store(path: String, modified: Date?, rgb: ReaderPalette.RGB) {
        lock.lock()
        defer { lock.unlock() }
        cache[path] = Entry(modified: modified, rgb: rgb)
    }
}
