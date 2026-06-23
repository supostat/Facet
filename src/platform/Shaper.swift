import CoreGraphics
import CoreText
import Foundation

// One shaped glyph: the Core-Text-resolved font, the glyph index, the glyph's
// origin in drawable pixels (top-left framebuffer space, on the baseline), and
// the horizontal advance to the next glyph. `origin` is the glyph's pen position
// — NOT the cell top-left — so it places the same point the rasterizer's bearing
// is measured against. Co-located with the Shaper the way RasterizedGlyph lives
// with GlyphRasterizer.
struct ShapedGlyph {
    let font: CTFont
    let glyph: CGGlyph
    let origin: SIMD2<Float>
    let advance: Float
}

// One shaped glyph's absolute placement geometry for the Phase-14b shape seam: the
// cell CENTER in drawable pixels, the full cell extent, and the glyph's normalized
// atlas sub-rectangle — the exact shape of `tree.PlacedGlyph` / `FacetPlacedGlyph`,
// header-free so it lives in Shaper (the ShapeCallback closure copies it field-for-
// field into a FacetPlacedGlyph). It is the same cell geometry `Shaper.instances`
// bakes into a `.glyph` Instance, only emitted as plain geometry the seam transports
// rather than a full Instance.
struct PlacedGlyphGeometry {
    let centerX: Float
    let centerY: Float
    let width: Float
    let height: Float
    let atlasMinU: Float
    let atlasMinV: Float
    let atlasMaxU: Float
    let atlasMaxV: Float
}

// The external scene supplier for proportionally-shaped text: turns a string into
// the [Instance] array the Renderer draws, one glyph instance per shaped glyph.
// Where TextLayout advances a FIXED monospace pen, the Shaper hands the string to
// Core Text (CTLineCreateWithAttributedString) and reads back the natural shaped
// positions — kerning, proportional advances, and any glyph substitution Core
// Text applies — from the CTRun glyphs. It does NOT rasterize: it positions and
// calls Atlas.lookup, the single Core Text imaging site living in the Atlas.
//
// The API is two levels. shape(string:font:origin:) is pure: it resolves each
// CTRun's font and emits ShapedGlyph values with no atlas or render dependency,
// so the deterministic position asserts can probe Core Text's shaping in
// isolation. instances(for:color:atlas:) is the assembly step: it looks each
// shaped glyph up in the atlas and builds the `.glyph` Instances, mirroring
// TextLayout's cell geometry exactly — only the per-glyph X comes from the CTRun
// instead of a fixed pen.
enum Shaper {
    // Shapes the string with Core Text and returns each glyph's resolved font,
    // index, top-left-space origin, and advance. The whole string carries a single
    // kCTFontAttributeName, so every run resolves to `font` (or a Core Text
    // fallback) — the attribute is always present by construction. An empty string
    // produces no runs and so returns an empty array.
    static func shape(
        string: String,
        font: CTFont,
        origin: (x: Float, y: Float)
    ) -> [ShapedGlyph] {
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        let attributed = CFAttributedStringCreate(nil, string as CFString, attributes)!
        let line = CTLineCreateWithAttributedString(attributed)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]

        var shaped: [ShapedGlyph] = []
        for run in runs {
            let glyphCount = CTRunGetGlyphCount(run)
            if glyphCount == 0 {
                continue
            }
            let runFont = resolveFont(of: run)
            let glyphs = copyGlyphs(of: run, count: glyphCount)
            let positions = copyPositions(of: run, count: glyphCount)
            let advances = copyAdvances(of: run, count: glyphCount)
            for index in 0..<glyphCount {
                shaped.append(
                    ShapedGlyph(
                        font: runFont,
                        glyph: glyphs[index],
                        origin: SIMD2<Float>(
                            origin.x + Float(positions[index].x),
                            origin.y - Float(positions[index].y)
                        ),
                        advance: Float(advances[index].width)
                    )
                )
            }
        }
        return shaped
    }

    // Assembles the shaped glyphs into `.glyph` Instances by looking each one up in
    // the atlas and offsetting its origin by the placement bearing — the same cell
    // geometry TextLayout produces, so SDF and glyph instances draw in one pass.
    static func instances(
        for shaped: [ShapedGlyph],
        color: (r: Float, g: Float, b: Float, a: Float),
        atlas: Atlas
    ) -> [Instance] {
        var instances: [Instance] = []
        for glyph in shaped {
            let placement = atlas.lookup(font: glyph.font, glyph: glyph.glyph)
            let cellWidth = Float(placement.pixelRect.width)
            let cellHeight = Float(placement.pixelRect.height)
            let cellLeft = glyph.origin.x + placement.bearing.x
            let cellTop = glyph.origin.y + placement.bearing.y
            let center = (x: cellLeft + cellWidth / 2, y: cellTop + cellHeight / 2)

            instances.append(
                Instance(
                    center: center,
                    size: (width: cellWidth, height: cellHeight),
                    color: color,
                    cornerRadius: 0,
                    type: .glyph,
                    atlasRect: placement.normalizedRect
                )
            )
        }
        return instances
    }

    // Shapes the string and emits each glyph's absolute placement geometry for the
    // Phase-14b shape seam, reusing the `shape` + `atlas.lookup` path but returning
    // plain `PlacedGlyphGeometry` (not `.glyph` Instances). `origin` is the laid-out
    // line origin in top-left drawable space, on the baseline (the caller derives
    // baseline_y = box_top + ascent). The ATLAS-GROW hazard (Ф4): atlas.lookup may
    // grow and RELOCATE every prior entry's normalizedRect, so ALL lookups run first
    // (forcing every rasterization + any grow to settle), THEN every normalizedRect
    // is read from a SECOND lookup against the now-stable atlas — never a rect read
    // before a later glyph triggers a grow. An empty string shapes to no glyphs.
    static func placedGlyphs(
        string: String,
        font: CTFont,
        origin: (x: Float, y: Float),
        atlas: Atlas
    ) -> [PlacedGlyphGeometry] {
        let shaped = shape(string: string, font: font, origin: origin)
        // First pass: look every glyph up so every rasterization and any atlas grow
        // happens now; the placements returned here may hold pre-grow rects, so they
        // are NOT read for geometry.
        for glyph in shaped {
            _ = atlas.lookup(font: glyph.font, glyph: glyph.glyph)
        }
        // Second pass: the atlas is stable (every glyph is cached, no further grow),
        // so each lookup is a hit returning the final normalizedRect.
        var placed: [PlacedGlyphGeometry] = []
        for glyph in shaped {
            let placement = atlas.lookup(font: glyph.font, glyph: glyph.glyph)
            let cellWidth = Float(placement.pixelRect.width)
            let cellHeight = Float(placement.pixelRect.height)
            let cellLeft = glyph.origin.x + placement.bearing.x
            let cellTop = glyph.origin.y + placement.bearing.y
            placed.append(
                PlacedGlyphGeometry(
                    centerX: cellLeft + cellWidth / 2,
                    centerY: cellTop + cellHeight / 2,
                    width: cellWidth,
                    height: cellHeight,
                    atlasMinU: placement.normalizedRect.minU,
                    atlasMinV: placement.normalizedRect.minV,
                    atlasMaxU: placement.normalizedRect.maxU,
                    atlasMaxV: placement.normalizedRect.maxV
                )
            )
        }
        return placed
    }

    // Measures a single line of text with Core Text for the Ф14 UPWARD measure seam
    // (Р10): the typographic WIDTH is the main-axis extent, ascent + descent +
    // leading the cross-axis extent. `CTLineGetTypographicBounds` returns the width
    // as its Double return value and writes the three vertical metrics through
    // out-params (the Ф6 measure precedent). An empty string produces a line with no
    // runs and zero bounds → (0, 0), the contract's empty-string result. This is the
    // SAME Core Text path the production `facetMeasureText` callback drives, so the
    // e2e seam-fidelity assert (Swift-measured == Zig-measured) holds by construction.
    static func measure(string: String, font: CTFont) -> (main: CGFloat, cross: CGFloat) {
        if string.isEmpty {
            return (0, 0)
        }
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        let attributed = CFAttributedStringCreate(nil, string as CFString, attributes)!
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return (main: CGFloat(width), cross: ascent + descent + leading)
    }

    // The run always carries the font attribute we set on the whole string, so a
    // missing attribute is a construction bug — the force-cast traps rather than
    // masking it with a fallback.
    private static func resolveFont(of run: CTRun) -> CTFont {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        return attributes[kCTFontAttributeName] as! CTFont
    }

    // CTRunGetGlyphs/Positions/Advances copy the WHOLE run into a pre-sized buffer
    // when given a zero-length CFRange (Core Text's documented "entire run"
    // shorthand). The buffer must already hold `count` elements.
    private static func copyGlyphs(of run: CTRun, count: Int) -> [CGGlyph] {
        var glyphs = [CGGlyph](repeating: 0, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        return glyphs
    }

    private static func copyPositions(of run: CTRun, count: Int) -> [CGPoint] {
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
        return positions
    }

    private static func copyAdvances(of run: CTRun, count: Int) -> [CGSize] {
        var advances = [CGSize](repeating: .zero, count: count)
        CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
        return advances
    }

    // The fixed family the measure seam resolves a CTFont from (Ф14 deviation a —
    // fixed family Swift-side, the MeasureRequest carries only the point size).
    // Matches the existing proportional reference text family.
    static let measureFontName = "Helvetica"
}
