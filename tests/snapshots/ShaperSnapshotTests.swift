import CoreText
import Foundation

// Golden-PNG snapshot + deterministic position test for the Phase 6 Core Text line
// shaper: the production Renderer drawing `.glyph` Instances that the Shaper
// positioned from CTRun glyphs (kerning + proportional advances), through the same
// glyph branch of the single SDF pipeline TextSnapshotTests exercises. The golden
// compares mirror that suite (premultiplied BGRA, AA tolerance via
// SnapshotComparator). The golden-INDEPENDENT half asserts real Core Text shaping
// the golden cannot vouch for: a proportional line's glyph origins strictly
// increase (no overlap, no fixed pen), a kerning pair shapes NARROWER than the
// naive per-glyph advance sum, and a monospace face shapes to one shared advance.
// These probe Shaper.shape directly, so they are not tautologies — a fixed-pen or
// kerning-blind shaper would fail them.
@main
struct ShaperSnapshotTests {
    private static let referenceWidth = 1024
    private static let referenceHeight = 640

    // A channel must move by more than this many 1/255 steps to count as "text
    // rendered here" rather than golden AA noise on the clear color.
    private static let strokeChannelDelta = 10

    // Kerning verdict slack: the shaped pair must be at least this many pixels
    // narrower than the naive advance sum. AV/Helvetica 32pt kerns ~2.36px, so a
    // 1px floor proves real kerning without pinning the exact metric.
    private static let kerningMinimumReduction: Float = 1.0

    // Monospace verdict slack: every advance must equal the first within this many
    // pixels — a true monospace face is identical to well under 0.01px.
    private static let monospaceAdvanceTolerance: Float = 0.01

    static func main() {
        let renderer = Renderer(metallibPath: MetallibLocator.resolve())
        runEdgeCases(renderer)
        runProportionalLine(renderer)
        runKerningPair(renderer)
        runMonospaceRegression(renderer)
        runDrawCallMetric(renderer)
        print("shaper-snapshot-test: all cases passed")
    }

    // Edge cases on the pure shaping step: an empty string yields no runs and so
    // no shaped glyphs (and no instances), and a single glyph yields exactly one.
    private static func runEdgeCases(_ renderer: Renderer) {
        let empty = Shaper.shape(string: "", font: ReferenceText.font(), origin: (0, 0))
        precondition(empty.isEmpty, "empty string must yield zero shaped glyphs, got \(empty.count)")
        let emptyInstances = Shaper.instances(for: empty, color: ReferenceText.textColor, atlas: renderer.atlas)
        precondition(emptyInstances.isEmpty, "empty string must yield zero instances, got \(emptyInstances.count)")

        let single = Shaper.shape(string: "i", font: ReferenceText.font(), origin: (0, 0))
        precondition(single.count == 1, "single-glyph string must yield exactly one shaped glyph, got \(single.count)")
    }

    private static func runProportionalLine(_ renderer: Renderer) {
        let shaped = Shaper.shape(
            string: ReferenceText.proportionalString,
            font: ReferenceText.font(),
            origin: ReferenceText.proportionalStartPosition
        )
        // 'iWmil' carries no default ligature, so the shaped glyph count equals the
        // scalar count — the asserts below operate on shaped order one-to-one.
        precondition(
            shaped.count == ReferenceText.proportionalString.unicodeScalars.count,
            "proportional: ligature-free string must shape one glyph per scalar, got \(shaped.count)"
        )

        // Glyph origins strictly increase along the line: no glyph overlaps its
        // predecessor and the pen is not fixed. A monospace-fixed or zero-advance
        // shaper would fail this.
        for index in 1..<shaped.count {
            precondition(
                shaped[index].origin.x > shaped[index - 1].origin.x,
                "proportional: glyph origins must strictly increase, "
                    + "x[\(index)]=\(shaped[index].origin.x) <= x[\(index - 1)]=\(shaped[index - 1].origin.x)"
            )
        }

        let scene = Shaper.instances(for: shaped, color: ReferenceText.textColor, atlas: renderer.atlas)
        let frame = renderer.captureSdfFrame(scene, width: referenceWidth, height: referenceHeight)
        SnapshotComparator.compareBgra(frame, goldenName: ReferenceText.proportionalLineGoldenName)

        // (1) A glyph stroke darkens the clear color inside the first cell.
        let strokePixel = findStrokePixel(frame, inCellOf: scene[0])
        precondition(
            strokePixel != nil,
            "proportional(1): no glyph stroke found in the first cell — text not rendered"
        )

        // (2) Premultiplied over the opaque clear pins alpha to 255.
        precondition(
            strokePixel!.alpha == 255,
            "proportional(2): premultiplied-over-opaque must pin alpha to 255, got \(strokePixel!.alpha)"
        )

        // (3) A pixel in a known-empty band above the text is exactly the clear
        // color: the glyph quads do not bleed there.
        assertEqualsClearColor(pixel(frame, 60, 60), label: "proportional(3)")
    }

    private static func runKerningPair(_ renderer: Renderer) {
        let font = ReferenceText.font()
        let shaped = Shaper.shape(
            string: ReferenceText.kerningString,
            font: font,
            origin: ReferenceText.kerningStartPosition
        )
        precondition(
            shaped.count == ReferenceText.kerningString.unicodeScalars.count,
            "kerning: ligature-free pair must shape one glyph per scalar, got \(shaped.count)"
        )

        // Shaped pair width: the last glyph's pen offset from the line origin plus
        // its own advance. The naive sum ignores the AV kerning pair, so the shaped
        // width must come out strictly narrower — proving Core Text applied kerning.
        let shapedPairWidth = (shaped[shaped.count - 1].origin.x - ReferenceText.kerningStartPosition.x)
            + shaped[shaped.count - 1].advance
        let naiveSum = naiveAdvanceSum(of: shaped, in: font)
        precondition(
            shapedPairWidth < naiveSum - kerningMinimumReduction,
            "kerning: shaped width \(shapedPairWidth) must be at least \(kerningMinimumReduction)px "
                + "narrower than the naive advance sum \(naiveSum) — kerning not applied"
        )

        let scene = Shaper.instances(for: shaped, color: ReferenceText.textColor, atlas: renderer.atlas)
        let frame = renderer.captureSdfFrame(scene, width: referenceWidth, height: referenceHeight)
        SnapshotComparator.compareBgra(frame, goldenName: ReferenceText.kerningPairGoldenName)

        let strokePixel = findStrokePixel(frame, inCellOf: scene[0])
        precondition(
            strokePixel != nil,
            "kerning: no glyph stroke found in the first cell — text not rendered"
        )
    }

    private static func runMonospaceRegression(_ renderer: Renderer) {
        let shaped = Shaper.shape(
            string: ReferenceText.monospaceString,
            font: ReferenceText.monospaceFont(),
            origin: ReferenceText.monospaceStartPosition
        )
        precondition(
            shaped.count == ReferenceText.monospaceString.unicodeScalars.count,
            "monospace: ligature-free string must shape one glyph per scalar, got \(shaped.count)"
        )

        // A monospace face advances every glyph by one shared width: the shaped
        // advances must all equal the first to within a hair. A proportional face
        // (or a shaper that recomputed advances from glyph widths) would diverge.
        let firstAdvance = shaped[0].advance
        for index in 1..<shaped.count {
            let delta = abs(shaped[index].advance - firstAdvance)
            precondition(
                delta < monospaceAdvanceTolerance,
                "monospace: advance[\(index)]=\(shaped[index].advance) must equal "
                    + "advance[0]=\(firstAdvance) within \(monospaceAdvanceTolerance), delta \(delta)"
            )
        }

        let scene = Shaper.instances(for: shaped, color: ReferenceText.textColor, atlas: renderer.atlas)
        let frame = renderer.captureSdfFrame(scene, width: referenceWidth, height: referenceHeight)
        SnapshotComparator.compareBgra(frame, goldenName: ReferenceText.monospaceRegressionGoldenName)

        let strokePixel = findStrokePixel(frame, inCellOf: scene[0])
        precondition(
            strokePixel != nil,
            "monospace: no glyph stroke found in the first cell — text not rendered"
        )
    }

    private static func runDrawCallMetric(_ renderer: Renderer) {
        SnapshotComparator.assertSingleDrawSingleCommit(
            renderer,
            scene: ReferenceText.proportionalLineScene(atlas: renderer.atlas),
            width: referenceWidth,
            height: referenceHeight
        )
    }

    // The naive (kerning-blind) total advance: each shaped glyph measured on its
    // own with CTFontGetAdvancesForGlyphs, summed. The shaped pair beats this sum
    // exactly when Core Text applies a negative kerning adjustment.
    private static func naiveAdvanceSum(of shaped: [ShapedGlyph], in font: CTFont) -> Float {
        var glyphs = shaped.map { $0.glyph }
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advances, glyphs.count)
        return advances.reduce(Float(0)) { $0 + Float($1.width) }
    }

    // Scans the drawable-pixel cell of a glyph instance for the first pixel that
    // differs from the clear color by more than AA noise — a rendered stroke.
    private static func findStrokePixel(
        _ frame: CapturedFrame,
        inCellOf instance: Instance
    ) -> (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8)? {
        let clear = clearColorBytes()
        return findPixel(frame, inCellOf: instance) { candidate in
            channelDistance(candidate, clear) > strokeChannelDelta
        }
    }

    private static func findPixel(
        _ frame: CapturedFrame,
        inCellOf instance: Instance,
        where predicate: ((blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8)) -> Bool
    ) -> (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8)? {
        let minX = max(0, Int((instance.positionX - instance.width / 2).rounded(.down)))
        let maxX = min(frame.width - 1, Int((instance.positionX + instance.width / 2).rounded(.up)))
        let minY = max(0, Int((instance.positionY - instance.height / 2).rounded(.down)))
        let maxY = min(frame.height - 1, Int((instance.positionY + instance.height / 2).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return nil }
        for y in minY...maxY {
            for x in minX...maxX {
                let candidate = pixel(frame, x, y)
                if predicate(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func pixel(
        _ frame: CapturedFrame,
        _ x: Int,
        _ y: Int
    ) -> (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8) {
        SnapshotComparator.pixel(frame, x, y)
    }

    private static func channelDistance(
        _ first: (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8),
        _ second: (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8)
    ) -> Int {
        max(
            abs(Int(first.blue) - Int(second.blue)),
            max(
                abs(Int(first.green) - Int(second.green)),
                abs(Int(first.red) - Int(second.red))
            )
        )
    }

    private static func channelToByte(_ component: Float) -> UInt8 {
        UInt8((Double(component) * 255.0).rounded())
    }

    private static func clearColorBytes() -> (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8) {
        let clear = Renderer.clearColor
        return (
            blue: channelToByte(Float(clear.blue)),
            green: channelToByte(Float(clear.green)),
            red: channelToByte(Float(clear.red)),
            alpha: channelToByte(Float(clear.alpha))
        )
    }

    private static func assertEqualsClearColor(
        _ rendered: (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8),
        label: String
    ) {
        let expected = clearColorBytes()
        precondition(channelWithin(rendered.blue, expected.blue), "\(label): blue \(rendered.blue) != \(expected.blue)")
        precondition(channelWithin(rendered.green, expected.green), "\(label): green \(rendered.green) != \(expected.green)")
        precondition(channelWithin(rendered.red, expected.red), "\(label): red \(rendered.red) != \(expected.red)")
        precondition(channelWithin(rendered.alpha, expected.alpha), "\(label): alpha \(rendered.alpha) != \(expected.alpha)")
    }

    private static func channelWithin(_ rendered: UInt8, _ expected: UInt8) -> Bool {
        let delta = rendered > expected ? rendered - expected : expected - rendered
        return delta <= SnapshotComparator.maxChannelDelta
    }
}
