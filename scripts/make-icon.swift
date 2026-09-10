// Generates the Margins app icons: a cream paper page with a body-text
// column and a rust-colored margin note — minimal, matching the reader's
// palette. Run from the repo root:
//   swift scripts/make-icon.swift scripts/assets
// Expects scripts/assets to exist. Writes the macOS Margins.iconset there
// (via iconutil downstream) and the committed iOS asset catalog at
// apple/ios/Margins/Assets.xcassets (single 1024 icon, edge-to-edge and
// opaque — iOS masks corners itself and App Store Connect rejects alpha).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024
let macArtwork = CGRect(x: 100, y: 100, width: 824, height: 824) // Big Sur grid
let cornerRadius: CGFloat = 185.4

// Palette (matches the reading surface: cream paper, ink, warm note).
let paperTop = CGColor(red: 0.969, green: 0.957, blue: 0.933, alpha: 1)
let paperBottom = CGColor(red: 0.933, green: 0.918, blue: 0.878, alpha: 1)
let ink = CGColor(red: 0.067, green: 0.067, blue: 0.067, alpha: 0.85)
let note = CGColor(red: 0.702, green: 0.333, blue: 0.180, alpha: 0.92)

func drawIcon(scale: CGFloat, artwork: CGRect, cornerRadius: CGFloat, border: Bool, opaque: Bool) -> CGImage {
    let side = canvas * scale
    let alphaInfo: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    let context = CGContext(
        data: nil, width: Int(side), height: Int(side),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: alphaInfo.rawValue
    )!
    context.scaleBy(x: scale, y: scale)
    // Draw with a top-left origin so the design reads like a page.
    context.translateBy(x: 0, y: canvas)
    context.scaleBy(x: 1, y: -1)

    // Paper squircle with a subtle vertical gradient.
    let path = CGPath(roundedRect: artwork, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [paperTop, paperBottom] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: artwork.midX, y: artwork.minY),
        end: CGPoint(x: artwork.midX, y: artwork.maxY),
        options: []
    )

    // Hairline border keeps the paper readable on light backgrounds.
    if border {
        context.setStrokeColor(ink.copy(alpha: 0.18)!)
        context.setLineWidth(3)
        context.addPath(path)
        context.strokePath()
    }

    // Margin rule at roughly 30% across the page.
    let ruleX = artwork.minX + artwork.width * 0.30
    let ruleTop = artwork.minY + artwork.height * 0.17
    let ruleBottom = artwork.minY + artwork.height * 0.83
    context.setStrokeColor(note.copy(alpha: 0.75)!)
    context.setLineWidth(5)
    context.move(to: CGPoint(x: ruleX, y: ruleTop))
    context.addLine(to: CGPoint(x: ruleX, y: ruleBottom))
    context.strokePath()

    // Body text column: five rounded "lines" to the right of the rule.
    func capsule(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: CGColor) {
        let rect = CGRect(x: x, y: y, width: width, height: height)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        context.setFillColor(color)
        context.fillPath()
    }

    let bodyLineHeight: CGFloat = 30
    let bodyGap: CGFloat = 78
    var bodyY = artwork.minY + artwork.height * 0.22
    let bodyWidths: [CGFloat] = [440, 460, 430, 455, 320]
    for width in bodyWidths {
        capsule(ruleX + 32, bodyY, width, bodyLineHeight, ink)
        bodyY += bodyGap
    }

    // The margin note: short rust lines in the margin, with a leader
    // curving out to the first body line.
    let noteLineHeight: CGFloat = 20
    let noteX = artwork.minX + artwork.width * 0.075
    let noteWidths: [CGFloat] = [150, 178, 132]
    var noteY = artwork.minY + artwork.height * 0.23
    for width in noteWidths {
        capsule(noteX, noteY, width, noteLineHeight, note)
        noteY += 46
    }
    context.setStrokeColor(note.copy(alpha: 0.85)!)
    context.setLineWidth(4)
    context.move(to: CGPoint(x: noteX + 160, y: noteY - 46 - noteLineHeight / 2))
    context.addQuadCurve(
        to: CGPoint(x: ruleX + 26, y: artwork.minY + artwork.height * 0.225 + bodyLineHeight / 2),
        control: CGPoint(x: ruleX - 10, y: noteY - 60)
    )
    context.strokePath()

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "make-icon", code: 2)
    }
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "scripts/assets")
let iconset = outputDir.appendingPathComponent("Margins.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(name: String, points: CGFloat, scale: CGFloat)] = [
    ("icon_16x16", 16, 1), ("icon_16x16@2x", 16, 2),
    ("icon_32x32", 32, 1), ("icon_32x32@2x", 32, 2),
    ("icon_128x128", 128, 1), ("icon_128x128@2x", 128, 2),
    ("icon_256x256", 256, 1), ("icon_256x256@2x", 256, 2),
    ("icon_512x512", 512, 1), ("icon_512x512@2x", 512, 2),
]
for spec in sizes {
    let image = drawIcon(
        scale: spec.points * spec.scale / canvas,
        artwork: macArtwork,
        cornerRadius: cornerRadius,
        border: true,
        opaque: false
    )
    try writePNG(image, to: iconset.appendingPathComponent("\(spec.name).png"))
}
print("iconset written to \(iconset.path)")

// iOS: one committed 1024×1024 in an asset catalog, edge-to-edge square
// (iOS rounds the corners itself) and alpha-free (App Store Connect
// rejects alpha in marketing icons).
let appiconset = URL(fileURLWithPath: "apple/ios/Margins/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: appiconset, withIntermediateDirectories: true)
let iosIcon = drawIcon(scale: 1, artwork: CGRect(x: 0, y: 0, width: canvas, height: canvas), cornerRadius: 0, border: false, opaque: true)
try writePNG(iosIcon, to: appiconset.appendingPathComponent("icon1024.png"))
let catalogInfo = #"{"info":{"author":"xcode","version":1}}"#
try catalogInfo.write(
    to: appiconset.deletingLastPathComponent().appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)
let appiconContents = """
{
  "images" : [
    {
      "filename" : "icon1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try appiconContents.write(to: appiconset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("iOS app icon written to \(appiconset.path)")
