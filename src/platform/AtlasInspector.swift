import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

// A point-in-time view of the atlas collected in a single pass on Atlas. One
// snapshot feeds BOTH the machine and pretty dumps (single collector, dual
// output — no separate pretty collector). Entries are in insertion order, so the
// dump is deterministic for a fixed insert sequence.
struct AtlasSnapshot {
    struct Entry {
        let fontName: String
        let pointSize: CGFloat
        let glyph: CGGlyph
        let placement: GlyphPlacement
    }

    let size: Int
    let shelfCount: Int
    let entries: [Entry]

    var occupiedPixels: Int {
        entries.reduce(0) { total, entry in
            total + entry.placement.pixelRect.width * entry.placement.pixelRect.height
        }
    }

    var fillRatio: Double {
        Double(occupiedPixels) / Double(size * size)
    }
}

// Formats an AtlasSnapshot and exports the atlas texture. machineDump is the
// DEFAULT, deterministic output: every float field is pinned with an explicit
// format string, the font name is the stable PostScript name, entries are
// emitted in insertionIndex order, and there are no pointer/hash/locale-dependent
// fields — so a fixed insert sequence yields a byte-identical dump. prettyDump
// renders the SAME snapshot in an aligned human-readable form. writeTexturePng
// exports the R8 atlas as a deviceGray PNG (no colormatch) for the golden;
// readTextureBytes reads the R8 texture back in top-left atlas space for the
// snapshot compare.
enum AtlasInspector {
    static func machineDump(_ snapshot: AtlasSnapshot) -> String {
        var lines: [String] = []
        for entry in snapshot.entries {
            let rect = entry.placement.pixelRect
            let normalized = entry.placement.normalizedRect
            lines.append(
                "entry index=\(entry.placement.insertionIndex)"
                    + " font=\(entry.fontName)"
                    + " size=\(format1(entry.pointSize))"
                    + " glyph=\(entry.glyph)"
                    + " px=\(rect.x),\(rect.y),\(rect.width),\(rect.height)"
                    + " uv=\(format4(normalized.minU)),\(format4(normalized.minV)),"
                    + "\(format4(normalized.maxU)),\(format4(normalized.maxV))"
                    + " bearing=\(format1(entry.placement.bearing.x)),\(format1(entry.placement.bearing.y))"
                    + " advance=\(format1(entry.placement.advance))"
            )
        }
        lines.append(
            "summary size=\(snapshot.size)"
                + " shelves=\(snapshot.shelfCount)"
                + " entries=\(snapshot.entries.count)"
                + " occupied=\(snapshot.occupiedPixels)"
                + " free=\(snapshot.size * snapshot.size - snapshot.occupiedPixels)"
                + " fill=\(format4(Float(snapshot.fillRatio)))"
        )
        return lines.joined(separator: "\n")
    }

    static func prettyDump(_ snapshot: AtlasSnapshot) -> String {
        var lines: [String] = []
        lines.append(
            "Atlas \(snapshot.size)x\(snapshot.size), "
                + "\(snapshot.shelfCount) shelves, \(snapshot.entries.count) entries"
        )
        lines.append(
            "  "
                + pad("index", 6)
                + pad("font", 24)
                + pad("size", 7)
                + pad("glyph", 7)
                + pad("pixelRect", 20)
                + pad("bearing", 16)
                + "advance"
        )
        for entry in snapshot.entries {
            let rect = entry.placement.pixelRect
            let pixelRect = "\(rect.x),\(rect.y) \(rect.width)x\(rect.height)"
            let bearing = "\(format1(entry.placement.bearing.x)),\(format1(entry.placement.bearing.y))"
            lines.append(
                "  "
                    + pad(String(entry.placement.insertionIndex), 6)
                    + pad(entry.fontName, 24)
                    + pad(format1(entry.pointSize), 7)
                    + pad(String(entry.glyph), 7)
                    + pad(pixelRect, 20)
                    + pad(bearing, 16)
                    + format1(entry.placement.advance)
            )
        }
        lines.append(
            "  occupied=\(snapshot.occupiedPixels)"
                + " free=\(snapshot.size * snapshot.size - snapshot.occupiedPixels)"
                + " fill=\(format4(Float(snapshot.fillRatio)))"
        )
        return lines.joined(separator: "\n")
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    // Reads the full R8 atlas texture into a top-left row-ordered byte array.
    // bytesPerRow == width because R8 is one byte per pixel on a .shared texture
    // (no 256-byte alignment, which is blit/buffer-backed only).
    static func readTextureBytes(_ texture: MTLTexture) -> [UInt8] {
        let width = texture.width
        let height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let region = MTLRegionMake2D(0, 0, width, height)
        pixels.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: width,
                from: region,
                mipmapLevel: 0
            )
        }
        return pixels
    }

    // Exports the R8 atlas as a deviceGray PNG with no colormatch (untagged
    // deviceGray, alpha .none) — the grayscale analogue of the RGBA golden
    // round-trip, kept self-contained on the inspector so production code never
    // depends on the test-only RGBA PngImage. write(texture) bytes equal a later
    // deviceGray read of the file, so the snapshot compare has no ICC drift.
    static func writeTexturePng(_ texture: MTLTexture, to url: URL) {
        let pixels = readTextureBytes(texture)
        let width = texture.width
        let height = texture.height
        let image = makeGrayCGImage(grayPixels: pixels, width: width, height: height)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            fatalError("AtlasInspector.writeTexturePng: could not create a PNG destination at \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            fatalError("AtlasInspector.writeTexturePng: failed to finalize the PNG at \(url.path)")
        }
    }

    private static func makeGrayCGImage(grayPixels: [UInt8], width: Int, height: Int) -> CGImage {
        var pixels = grayPixels
        guard let context = pixels.withUnsafeMutableBytes({ buffer in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        }) else {
            fatalError("AtlasInspector.writeTexturePng: could not create a deviceGray encode context (\(width)x\(height))")
        }
        guard let image = context.makeImage() else {
            fatalError("AtlasInspector.writeTexturePng: could not snapshot the gray context to a CGImage")
        }
        return image
    }

    private static func format1(_ value: Float) -> String {
        String(format: "%.1f", value)
    }

    private static func format1(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    private static func format4(_ value: Float) -> String {
        String(format: "%.4f", value)
    }
}
