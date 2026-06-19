import CoreText
import Foundation

// The single definition of the fixed text scenes shared by the golden writer (the
// bench --write-reference path) and the golden compare (TextSnapshotTests),
// analogous to Instance.referenceScene and ReferenceAtlas. Both build the EXACT
// same [Instance] arrays — same font, same point size, same monospace advance,
// same ordered strings, same start positions, same SDF rect — so the committed
// text_*.png goldens and the test renders are the same frames.
//
// Determinism: the glyph sequences are explicit ORDERED String constants (never a
// Set/Dictionary iteration), and a single fontName + pointSize is used by BOTH the
// bench writer and the test. The Atlas caches on PostScript name + point size, so
// a divergence in either would yield different uv rects and break byte-identity.
enum ReferenceText {
    static let referenceStringGoldenName = "text_reference_string.png"
    static let mixedFrameGoldenName = "text_mixed_frame.png"
    static let twoColorsGoldenName = "text_two_colors_same_glyphs.png"

    // Phase 6 goldens: a proportionally shaped line, a kerning-bearing pair, and a
    // monospace font run THROUGH the Shaper (the fixed-advance regression — proving
    // the shaper's natural advances reduce to a monospace cadence for a monospace
    // face, with TextLayout kept as the explicit reference).
    static let proportionalLineGoldenName = "phase6-proportional-line.png"
    static let kerningPairGoldenName = "phase6-kerning-pair.png"
    static let monospaceRegressionGoldenName = "phase6-monospace-regression.png"

    static let fontName = "Helvetica"
    static let pointSize: CGFloat = 32
    // Fixed monospace pen advance in pixels: wide enough that 32pt Helvetica
    // glyphs do not collide, narrow enough that 17 cells fit a 1024px frame.
    static let cellAdvance: Float = 28

    // 17 characters (including the space), so glyphInstances returns >= 17
    // Instances and forces the Renderer's instance buffer to grow past its
    // 16-instance minimum capacity.
    static let referenceString = "Facet Glyph Atlas"
    static let referenceStartPosition: (x: Float, y: Float) = (60, 320)
    static let textColor: (r: Float, g: Float, b: Float, a: Float) = (0.95, 0.95, 0.98, 1.0)

    // Mixed frame: one SDF rounded rect with text composited on top, both in one
    // [Instance], proving the single-shader branch draws SDF and glyphs together.
    static let mixedRectColor: (r: Float, g: Float, b: Float, a: Float) = (0.20, 0.55, 0.95, 1.0)
    static let mixedRect = Instance(
        center: (x: 512, y: 320),
        size: (width: 760, height: 180),
        color: mixedRectColor,
        cornerRadius: 32
    )
    static let mixedString = "Facet"
    static let mixedStartPosition: (x: Float, y: Float) = (220, 330)
    static let mixedTextColor: (r: Float, g: Float, b: Float, a: Float) = (1.0, 1.0, 1.0, 1.0)

    // Two-colors: the SAME string assembled twice at two baselines in two distinct
    // colors from the SAME atlas — the shapes are reused (no re-rasterization), the
    // color comes only from the instance.
    static let twoColorsString = "Facet"
    static let twoColorsRunA: (color: (r: Float, g: Float, b: Float, a: Float), start: (x: Float, y: Float)) = (
        color: (1.0, 0.20, 0.20, 1.0),
        start: (200, 240)
    )
    static let twoColorsRunB: (color: (r: Float, g: Float, b: Float, a: Float), start: (x: Float, y: Float)) = (
        color: (0.20, 0.85, 0.95, 1.0),
        start: (200, 420)
    )

    // Phase 6 monospace face: every glyph shares one advance, so a run through the
    // Shaper must reproduce a monospace cadence (the equal-advances unit) while the
    // golden eye-checks the same proportional path.
    static let monospaceFontName = "Menlo"

    // Ligature-free strings: Core Text forms ligatures by default (fi -> one
    // glyph), which would break the count==scalar-count edge assert and the
    // shaped-order position asserts. iWmil/AV/To carry no default ligatures.
    static let proportionalString = "iWmil"
    static let proportionalStartPosition: (x: Float, y: Float) = (80, 320)

    static let kerningString = "AV"
    static let kerningStartPosition: (x: Float, y: Float) = (200, 320)

    static let monospaceString = "iWmil"
    static let monospaceStartPosition: (x: Float, y: Float) = (80, 320)

    static func font() -> CTFont {
        CTFontCreateWithName(fontName as CFString, pointSize, nil)
    }

    static func monospaceFont() -> CTFont {
        CTFontCreateWithName(monospaceFontName as CFString, pointSize, nil)
    }

    static func referenceStringScene(atlas: Atlas) -> [Instance] {
        TextLayout.glyphInstances(
            string: referenceString,
            color: textColor,
            startPosition: referenceStartPosition,
            cellAdvance: cellAdvance,
            font: font(),
            atlas: atlas
        )
    }

    static func mixedFrameScene(atlas: Atlas) -> [Instance] {
        var scene: [Instance] = [mixedRect]
        scene.append(
            contentsOf: TextLayout.glyphInstances(
                string: mixedString,
                color: mixedTextColor,
                startPosition: mixedStartPosition,
                cellAdvance: cellAdvance,
                font: font(),
                atlas: atlas
            )
        )
        return scene
    }

    static func twoColorsScene(atlas: Atlas) -> [Instance] {
        var scene = TextLayout.glyphInstances(
            string: twoColorsString,
            color: twoColorsRunA.color,
            startPosition: twoColorsRunA.start,
            cellAdvance: cellAdvance,
            font: font(),
            atlas: atlas
        )
        scene.append(
            contentsOf: TextLayout.glyphInstances(
                string: twoColorsString,
                color: twoColorsRunB.color,
                startPosition: twoColorsRunB.start,
                cellAdvance: cellAdvance,
                font: font(),
                atlas: atlas
            )
        )
        return scene
    }

    static func proportionalLineScene(atlas: Atlas) -> [Instance] {
        let shaped = Shaper.shape(
            string: proportionalString,
            font: font(),
            origin: proportionalStartPosition
        )
        return Shaper.instances(for: shaped, color: textColor, atlas: atlas)
    }

    static func kerningPairScene(atlas: Atlas) -> [Instance] {
        let shaped = Shaper.shape(
            string: kerningString,
            font: font(),
            origin: kerningStartPosition
        )
        return Shaper.instances(for: shaped, color: textColor, atlas: atlas)
    }

    static func monospaceRegressionScene(atlas: Atlas) -> [Instance] {
        let shaped = Shaper.shape(
            string: monospaceString,
            font: monospaceFont(),
            origin: monospaceStartPosition
        )
        return Shaper.instances(for: shaped, color: textColor, atlas: atlas)
    }
}
