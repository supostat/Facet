import CoreGraphics
import CoreText
import Foundation

// One rasterized glyph: a tightly-cropped R8 alpha mask plus the typographic
// metrics needed to position it. `alphaMask` is `width * height` bytes, one byte
// per pixel, laid out in TOP-LEFT row order — the orientation ShelfPacker places
// into and texture.replace uploads. `bearing` is the offset from the glyph
// origin (pen position, baseline) to the mask's top-left corner in pixels, with
// Y growing downward (top-left convention). `advance` is the horizontal pen
// advance in pixels.
struct RasterizedGlyph {
    let width: Int
    let height: Int
    let alphaMask: [UInt8]
    let bearing: SIMD2<Float>
    let advance: Float
}

// The ONLY Core Text imaging site. Turns a (CTFont, CGGlyph) into an R8 alpha
// mask via a deviceGray CGContext. The context's DRAWING origin is bottom-left,
// but its BACKING MEMORY is already top-row-first (row 0 is the top of the
// image) — exactly the top-left order the packer places into and texture.replace
// uploads — so the mask is returned with no row reordering. `rasterizationCount`
// is a machine-observable metric: it advances once per rasterize() call, so the
// atlas cache test can assert a repeated lookup does NOT re-rasterize.
final class GlyphRasterizer {
    private(set) var rasterizationCount: Int = 0

    // Resolves the CGGlyph for a Unicode scalar in the given font. Fails fast if
    // the font has no glyph for the scalar — a caller asking for an unmappable
    // character is a construction bug, not a runtime condition to mask.
    func glyph(for scalar: Unicode.Scalar, in font: CTFont) -> CGGlyph {
        let utf16 = Array(String(scalar).utf16)
        var characters = utf16.map { unichar($0) }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        let resolved = CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
        precondition(
            resolved,
            "CTFont has no glyph for U+\(String(scalar.value, radix: 16, uppercase: true))"
        )
        return glyphs[0]
    }

    // Rasterizes a single glyph into a tight R8 alpha mask. An empty glyph (e.g.
    // a space) has a zero-area bounding box and yields a 1x1 transparent mask so
    // the atlas always stores a valid region while still recording the advance.
    func rasterize(glyph: CGGlyph, in font: CTFont) -> RasterizedGlyph {
        rasterizationCount += 1

        var glyphs = [glyph]
        var boundingRects = [CGRect](repeating: .zero, count: 1)
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphs, &boundingRects, 1)
        let boundingRect = boundingRects[0]

        var advances = [CGSize](repeating: .zero, count: 1)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advances, 1)
        let advance = Float(advances[0].width)

        let pixelWidth = Int(boundingRect.width.rounded(.up))
        let pixelHeight = Int(boundingRect.height.rounded(.up))
        if pixelWidth <= 0 || pixelHeight <= 0 {
            return RasterizedGlyph(
                width: 1,
                height: 1,
                alphaMask: [0],
                bearing: SIMD2<Float>(Float(boundingRect.minX), -Float(boundingRect.maxY)),
                advance: advance
            )
        }

        let mask = drawGlyphMask(
            glyph: glyph,
            in: font,
            boundingRect: boundingRect,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )

        // Bearing in top-left space: X is the left side bearing; Y is the
        // distance from the baseline up to the mask top, negated because Y grows
        // downward. boundingRect.maxY is the ascent of the glyph above baseline.
        let bearing = SIMD2<Float>(Float(boundingRect.minX), -Float(boundingRect.maxY))
        return RasterizedGlyph(
            width: pixelWidth,
            height: pixelHeight,
            alphaMask: mask,
            bearing: bearing,
            advance: advance
        )
    }

    private func drawGlyphMask(
        glyph: CGGlyph,
        in font: CTFont,
        boundingRect: CGRect,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> [UInt8] {
        let bytesPerRow = pixelWidth
        var mask = [UInt8](repeating: 0, count: bytesPerRow * pixelHeight)
        let colorSpace = CGColorSpaceCreateDeviceGray()

        mask.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                fatalError("GlyphRasterizer: could not create a deviceGray context (\(pixelWidth)x\(pixelHeight))")
            }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            // The DRAWING coordinate system is bottom-left, so shift the glyph by
            // its negative bounding-box origin to seat its corner at (0, 0) and
            // fill the context. The backing memory stays top-row-first, so the
            // returned buffer is already in top-left atlas order — no flip.
            var glyphToDraw = glyph
            var position = CGPoint(x: -boundingRect.minX, y: -boundingRect.minY)
            CTFontDrawGlyphs(font, &glyphToDraw, &position, 1, context)
        }
        return mask
    }
}
