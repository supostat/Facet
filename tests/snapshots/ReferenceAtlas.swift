import CoreText
import Foundation
import Metal

// The single definition of the fixed atlas content shared by the golden writer
// (the bench --write-reference path) and the golden compare (AtlasSnapshotTests),
// analogous to Instance.referenceScene. Both build the EXACT same atlas — same
// font, same point size, same glyph insertion order — so the committed
// atlas_dump.png golden and the test render are the same texture. The string
// mixes Latin and Cyrillic to exercise the multi-script path; insertion order is
// the iteration order of `glyphSequence` (the dump order is insertionIndex).
enum ReferenceAtlas {
    static let goldenName = "atlas/atlas_dump.png"

    private static let fontName = "Helvetica"
    private static let pointSize: CGFloat = 32
    // Latin uppercase, lowercase, digits, then a short Cyrillic run. A fixed,
    // explicit sequence so the packed layout is deterministic.
    private static let glyphSequence = "FacetGlyphAtlas0123456789ЖивеСловоПривет"

    static func build(device: MTLDevice) -> Atlas {
        let atlas = Atlas(device: device)
        let font = CTFontCreateWithName(fontName as CFString, pointSize, nil)
        let rasterizer = GlyphRasterizer()
        for character in glyphSequence {
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
                fatalError("ReferenceAtlas expects single-scalar characters, got \(character)")
            }
            _ = atlas.lookup(font: font, glyph: rasterizer.glyph(for: scalar, in: font))
        }
        return atlas
    }
}
