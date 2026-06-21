import CoreText
import Foundation
import Metal

// Logic test for the glyph atlas — no golden image, pure asserts on its own
// Metal device, building CTFonts directly and never constructing a Renderer (so
// it depends on neither Renderer.swift, MetallibLocator, nor glyph.metal in the
// metallib). It uses the test-only Atlas(device:initialSize:) for cheap
// deterministic overflow. Coverage: the rasterization counter (cache hit does no
// Core Text work), pairwise non-overlap across the full insert set, overflow ->
// grow with a valid in-bounds non-overlapping placement, a Cyrillic glyph, and
// the inspector's deterministic machine dump + pretty entry-count parity.
@main
struct AtlasTests {
    private static let fontSize: CGFloat = 24

    static func main() {
        let device = makeDevice()
        runRasterizationCounter(device: device)
        runPairwiseNonOverlap(device: device)
        runOverflowGrows(device: device)
        runCyrillicGlyph(device: device)
        runGlyphOrientation(device: device)
        runMachineDumpDeterminism(device: device)
        runPrettyDumpEntryParity(device: device)
        print("atlas-test: all cases passed")
    }

    // A repeated lookup of the same (font, glyph) hits the cache and does NOT
    // re-rasterize: the rasterization counter advances by exactly one across two
    // identical lookups. Uses a non-growth scenario so grow()'s re-rasterization
    // cannot perturb the count.
    private static func runRasterizationCounter(device: MTLDevice) {
        let atlas = Atlas(device: device, initialSize: Atlas.initialAtlasSize)
        let font = makeFont()
        let glyph = atlas.lookup(font: font, glyph: glyphIndex(for: "A", in: font))
        let countAfterFirst = atlas.rasterizationCount
        let again = atlas.lookup(font: font, glyph: glyphIndex(for: "A", in: font))
        let countAfterSecond = atlas.rasterizationCount

        precondition(
            countAfterFirst == 1,
            "first lookup must rasterize exactly once, got \(countAfterFirst)"
        )
        precondition(
            countAfterSecond == 1,
            "repeated lookup must hit the cache and not re-rasterize, got \(countAfterSecond)"
        )
        precondition(
            glyph.pixelRect == again.pixelRect,
            "cache hit must return the same placement"
        )
        print("counter: rasterizations=\(countAfterSecond)")
    }

    // Every pair of placed rectangles is disjoint, in-bounds, and non-empty for a
    // full Latin alphabet insert set. A bin-packer that double-books a cell would
    // overwrite a live glyph; this is the golden-independent overlap oracle.
    private static func runPairwiseNonOverlap(device: MTLDevice) {
        let atlas = Atlas(device: device, initialSize: Atlas.initialAtlasSize)
        let font = makeFont()
        let scalars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        var rectangles: [PackedRectangle] = []
        for character in scalars {
            let placement = atlas.lookup(font: font, glyph: glyphIndex(for: character, in: font))
            assertInBounds(placement.pixelRect, atlasSize: atlas.size, label: "non-overlap")
            rectangles.append(placement.pixelRect)
        }
        assertPairwiseDisjoint(rectangles, label: "non-overlap")
        print("non-overlap: rectangles=\(rectangles.count) all disjoint and in-bounds")
    }

    // A tiny initial atlas overflows on the first wide glyph set, forcing grow().
    // After growth the atlas is larger, and the FINAL layout — read from the
    // snapshot, not the historical pre-grow return values — is valid, in-bounds,
    // and non-overlapping, and nothing crashed. Each lookup's return must also be
    // in-bounds for the atlas size at that moment.
    private static func runOverflowGrows(device: MTLDevice) {
        let tinyInitialSize = 32
        let atlas = Atlas(device: device, initialSize: tinyInitialSize)
        let font = makeFont()
        let scalars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        for character in scalars {
            let placement = atlas.lookup(font: font, glyph: glyphIndex(for: character, in: font))
            assertInBounds(placement.pixelRect, atlasSize: atlas.size, label: "overflow")
        }
        precondition(
            atlas.size > tinyInitialSize,
            "atlas must have grown past \(tinyInitialSize), still \(atlas.size)"
        )
        let finalRectangles = atlas.snapshot().entries.map(\.placement.pixelRect)
        for rectangle in finalRectangles {
            assertInBounds(rectangle, atlasSize: atlas.size, label: "overflow")
        }
        assertPairwiseDisjoint(finalRectangles, label: "overflow")
        print("overflow: grew \(tinyInitialSize) -> \(atlas.size), rectangles=\(finalRectangles.count) valid")
    }

    // A vertically asymmetric glyph rasterizes RIGHT-SIDE UP, not mirrored. The
    // alpha mask is in top-left row order (row 0 is the glyph's visual top), so a
    // top-heavy glyph must carry more ink near the top of the mask than the bottom.
    // 'T' is top-heavy: its full-width crossbar sits at the cap line while only a
    // thin central stem reaches down, so the top quarter of the mask holds far more
    // coverage than the bottom quarter. A spurious vertical flip (the Phase-4
    // orientation bug) inverts 'T' into a bottom-heavy upside-down shape and trips
    // this assert. The check lives on the raw mask precisely because the golden
    // images are generated by this same code: a self-referential golden cannot
    // catch a mask flip, but this orientation oracle can.
    private static func runGlyphOrientation(device: MTLDevice) {
        let font = makeFont()
        let rasterizer = GlyphRasterizer()
        let mask = rasterizer.rasterize(glyph: glyphIndex(for: "T", in: font), in: font)
        precondition(
            mask.height >= 4,
            "orientation: 'T' mask is too short to split into quarters (height \(mask.height))"
        )

        let quarterHeight = mask.height / 4
        let topInk = inkInRows(mask, from: 0, upTo: quarterHeight)
        let bottomInk = inkInRows(mask, from: mask.height - quarterHeight, upTo: mask.height)
        precondition(
            topInk > bottomInk * 2,
            "orientation: 'T' must be top-heavy (crossbar at the top), but the mask is "
                + "bottom-heavy (top_ink=\(topInk) bottom_ink=\(bottomInk)) — the glyph is vertically flipped"
        )
        print("orientation: 'T' top_ink=\(topInk) bottom_ink=\(bottomInk) (top-heavy, upright)")
    }

    // Total alpha coverage across a half-open band of mask rows [from, upTo).
    private static func inkInRows(_ mask: RasterizedGlyph, from startRow: Int, upTo endRow: Int) -> Int {
        var total = 0
        for row in startRow..<endRow {
            let rowStart = row * mask.width
            for column in 0..<mask.width {
                total += Int(mask.alphaMask[rowStart + column])
            }
        }
        return total
    }

    // A Cyrillic letter (U+0416 Ж) resolves to a non-zero CGGlyph and rasterizes
    // to a valid, in-bounds placement — the atlas is genuinely multi-script, not
    // Latin-only.
    private static func runCyrillicGlyph(device: MTLDevice) {
        let atlas = Atlas(device: device, initialSize: Atlas.initialAtlasSize)
        let font = makeFont()
        let cyrillic = glyphIndex(for: "\u{0416}", in: font)
        precondition(cyrillic != 0, "expected a non-zero CGGlyph for U+0416, got 0")
        let placement = atlas.lookup(font: font, glyph: cyrillic)
        assertInBounds(placement.pixelRect, atlasSize: atlas.size, label: "cyrillic")
        precondition(
            placement.pixelRect.width > 0 && placement.pixelRect.height > 0,
            "cyrillic glyph rect must be non-empty, got \(placement.pixelRect)"
        )
        print("cyrillic: glyph=\(cyrillic) rect=\(placement.pixelRect)")
    }

    // The same insert sequence yields a byte-identical machine dump across two
    // independent atlases — the deterministic-dump oracle that pairs with the
    // self-referential golden.
    private static func runMachineDumpDeterminism(device: MTLDevice) {
        let dumpA = machineDumpForFixedSequence(device: device)
        let dumpB = machineDumpForFixedSequence(device: device)
        precondition(
            dumpA == dumpB,
            "machine dump must be deterministic for a fixed insert sequence:\n--- A ---\n\(dumpA)\n--- B ---\n\(dumpB)"
        )
        print("determinism: machine dumps byte-identical (\(dumpA.utf8.count) bytes)")
    }

    // The pretty dump describes the SAME snapshot as the machine dump: one line
    // per entry plus the header and summary, so its entry-count matches.
    private static func runPrettyDumpEntryParity(device: MTLDevice) {
        let atlas = Atlas(device: device, initialSize: Atlas.initialAtlasSize)
        let font = makeFont()
        let scalars = "Hello"
        for character in scalars {
            _ = atlas.lookup(font: font, glyph: glyphIndex(for: character, in: font))
        }
        let snapshot = atlas.snapshot()
        let pretty = AtlasInspector.prettyDump(snapshot)
        let prettyLines = pretty.split(separator: "\n", omittingEmptySubsequences: false)
        // Header line + column line + one line per entry + summary line.
        let expectedLines = 2 + snapshot.entries.count + 1
        precondition(
            prettyLines.count == expectedLines,
            "pretty dump must have \(expectedLines) lines for \(snapshot.entries.count) entries, got \(prettyLines.count)"
        )
        let machineLines = AtlasInspector.machineDump(snapshot)
            .split(separator: "\n", omittingEmptySubsequences: false)
        // One line per entry + summary line.
        precondition(
            machineLines.count == snapshot.entries.count + 1,
            "machine dump must have \(snapshot.entries.count + 1) lines, got \(machineLines.count)"
        )
        print("pretty: entries=\(snapshot.entries.count) prettyLines=\(prettyLines.count) machineLines=\(machineLines.count)")
    }

    private static func machineDumpForFixedSequence(device: MTLDevice) -> String {
        let atlas = Atlas(device: device, initialSize: Atlas.initialAtlasSize)
        let font = makeFont()
        for character in "Facet\u{0416}" {
            _ = atlas.lookup(font: font, glyph: glyphIndex(for: character, in: font))
        }
        return AtlasInspector.machineDump(atlas.snapshot())
    }

    private static func assertInBounds(_ rect: PackedRectangle, atlasSize: Int, label: String) {
        precondition(
            rect.x >= 0 && rect.y >= 0,
            "\(label): rect origin negative \(rect)"
        )
        precondition(
            rect.x + rect.width <= atlasSize && rect.y + rect.height <= atlasSize,
            "\(label): rect \(rect) overruns atlas \(atlasSize)"
        )
        precondition(
            rect.width > 0 && rect.height > 0,
            "\(label): rect empty \(rect)"
        )
    }

    private static func assertPairwiseDisjoint(_ rectangles: [PackedRectangle], label: String) {
        for first in 0..<rectangles.count {
            for second in (first + 1)..<rectangles.count {
                precondition(
                    !overlaps(rectangles[first], rectangles[second]),
                    "\(label): rectangles \(rectangles[first]) and \(rectangles[second]) overlap"
                )
            }
        }
    }

    private static func overlaps(_ first: PackedRectangle, _ second: PackedRectangle) -> Bool {
        let separatedX = first.x + first.width <= second.x || second.x + second.width <= first.x
        let separatedY = first.y + first.height <= second.y || second.y + second.height <= first.y
        return !(separatedX || separatedY)
    }

    private static func makeDevice() -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is unavailable: MTLCreateSystemDefaultDevice returned nil")
        }
        return device
    }

    private static func makeFont() -> CTFont {
        CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    }

    private static func glyphIndex(for character: Character, in font: CTFont) -> CGGlyph {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            fatalError("AtlasTests expects single-scalar characters, got \(character)")
        }
        return GlyphRasterizer().glyph(for: scalar, in: font)
    }
}
