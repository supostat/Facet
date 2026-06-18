import CoreText
import Foundation

// The external scene supplier for monospace text: turns a string into the
// [Instance] array the Renderer draws, one glyph instance per Unicode scalar.
// Each scalar is resolved to a CGGlyph by a local GlyphRasterizer (the scalar ->
// glyph mapping only; the Atlas's own rasterizer images the glyph on a cache
// miss), looked up in the atlas for its placement, and emitted as a `.glyph`
// Instance whose cell center and atlas sub-rectangle drive the sdf.metal glyph
// branch. The pen advances by a FIXED cellAdvance per scalar — monospace, not the
// glyph's natural advance — so columns align regardless of glyph width.
//
// Geometry matches the sdf_vertex glyph branch: positionX/Y is the cell CENTER in
// drawable pixels (top-left origin). The cell's top-left corner is the pen
// position offset by the glyph bearing (bearing.x is the left side bearing,
// bearing.y the negated ascent, both in top-left pixel space from GlyphRasterizer)
// and the cell extent is the glyph's tight pixelRect, so the center is the cell
// top-left plus half the extent.
enum TextLayout {
    static func glyphInstances(
        string: String,
        color: (r: Float, g: Float, b: Float, a: Float),
        startPosition: (x: Float, y: Float),
        cellAdvance: Float,
        font: CTFont,
        atlas: Atlas
    ) -> [Instance] {
        let rasterizer = GlyphRasterizer()
        var instances: [Instance] = []
        var penX = startPosition.x
        let baselineY = startPosition.y

        for scalar in string.unicodeScalars {
            let glyph = rasterizer.glyph(for: scalar, in: font)
            let placement = atlas.lookup(font: font, glyph: glyph)
            let cellWidth = Float(placement.pixelRect.width)
            let cellHeight = Float(placement.pixelRect.height)
            let cellLeft = penX + placement.bearing.x
            let cellTop = baselineY + placement.bearing.y
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
            penX += cellAdvance
        }
        return instances
    }
}
