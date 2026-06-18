import Foundation

// Golden-PNG snapshot + analytic spot-assert test for the Phase 5 text path: the
// production Renderer drawing `.glyph` Instances through the glyph branch of the
// single SDF pipeline, sampling the R8 atlas. SDF rects and glyphs share ONE
// instanced draw call. The golden compares mirror the SDF/Phase-3 suites
// (premultiplied BGRA on both sides, AA tolerance via SnapshotComparator). The
// analytic spot-asserts are golden-INDEPENDENT: a glyph stroke darkens/colors the
// clear color, a between-glyphs gap stays exactly clear, and a glyph drawn in two
// different instance colors differs in RGB — none of which a golden can vouch for
// itself. Premultiplied output over the OPAQUE clear pins framebuffer alpha to
// 255, so these asserts read RGB, not alpha.
@main
struct TextSnapshotTests {
    private static let referenceWidth = 1024
    private static let referenceHeight = 640

    // A channel must move by more than this many 1/255 steps to count as "text
    // rendered here" rather than golden AA noise on the clear color.
    private static let strokeChannelDelta = 10

    static func main() {
        let renderer = Renderer(metallibPath: MetallibLocator.resolve())
        runEmptyString(renderer)
        runReferenceString(renderer)
        runMixedFrame(renderer)
        runTwoColorsSameGlyphs(renderer)
        runDrawCallMetric(renderer)
        print("text-snapshot-test: all cases passed")
    }

    private static func runEmptyString(_ renderer: Renderer) {
        // The empty string has no Unicode scalars, so the pen never advances and no
        // glyph instance is emitted — an empty scene draws nothing.
        let scene = TextLayout.glyphInstances(
            string: "",
            color: ReferenceText.textColor,
            startPosition: ReferenceText.referenceStartPosition,
            cellAdvance: ReferenceText.cellAdvance,
            font: ReferenceText.font(),
            atlas: renderer.atlas
        )
        precondition(scene.isEmpty, "empty string must yield zero glyph instances")
    }

    private static func runReferenceString(_ renderer: Renderer) {
        let scene = ReferenceText.referenceStringScene(atlas: renderer.atlas)
        // 'Facet Glyph Atlas' is 17 characters, so the buffer must grow past the
        // 16-instance minimum — provably exercising growInstanceBuffer.
        precondition(
            scene.count >= 17,
            "reference string must yield >= 17 instances to force buffer growth, got \(scene.count)"
        )

        let frame = renderer.captureSdfFrame(scene, width: referenceWidth, height: referenceHeight)
        SnapshotComparator.compareBgra(frame, goldenName: ReferenceText.referenceStringGoldenName)

        // (1) A glyph stroke darkens the clear color: the first glyph's cell holds
        // ink, so some pixel inside it differs from the clear color by more than AA
        // noise. Scanning the cell (not pinning one pixel) is robust to sub-pixel
        // metrics while still proving the glyph branch rendered.
        let strokePixel = findStrokePixel(frame, inCellOf: scene[0])
        precondition(
            strokePixel != nil,
            "reference(1): no glyph stroke found in the first cell — text not rendered"
        )

        // (2) Premultiplied over the opaque clear pins alpha to 255 everywhere.
        precondition(
            strokePixel!.alpha == 255,
            "reference(2): premultiplied-over-opaque must pin alpha to 255, got \(strokePixel!.alpha)"
        )

        // (3) A pixel in a known-empty band above the text (well above the cap
        // line) is exactly the clear color: the glyph quads do not bleed there.
        assertEqualsClearColor(pixel(frame, 60, 60), label: "reference(3)")
    }

    private static func runMixedFrame(_ renderer: Renderer) {
        let scene = ReferenceText.mixedFrameScene(atlas: renderer.atlas)
        let frame = renderer.captureSdfFrame(scene, width: referenceWidth, height: referenceHeight)
        SnapshotComparator.compareBgra(frame, goldenName: ReferenceText.mixedFrameGoldenName)

        // (1) Deep inside the SDF rect, away from any glyph, the pixel is the
        // premultiplied rect color — the SDF branch is still correct in the mixed
        // array. The rect is centered (512, 320), 760x180. The probe sits at x=512
        // (the rect's horizontal center); the "Facet" run starts at x=220 and
        // advances 28px over 5 cells, so its glyph cells span only x≈220..360 — over
        // 150px of horizontal clearance keeps the probe off the text even if a font
        // or advance change shifts the glyphs, so it samples bare rect.
        let rectInterior = pixel(frame, 512, 400)
        assertEqualsPremultiplied(
            rectInterior,
            color: ReferenceText.mixedRectColor,
            label: "mixed(1)"
        )

        // (2) A glyph stroke over the rect differs from the bare-rect color: the
        // white text composited on top of the blue rect.
        let bareRect = premultipliedBytes(ReferenceText.mixedRectColor)
        let textInstances = Array(scene.dropFirst())
        let overRect = findPixel(frame, inCellOf: textInstances[0]) { candidate in
            channelDistance(candidate, bareRect) > strokeChannelDelta
        }
        precondition(
            overRect != nil,
            "mixed(2): no glyph stroke differing from the bare rect color — text not composited on top"
        )
    }

    private static func runTwoColorsSameGlyphs(_ renderer: Renderer) {
        // Snapshot the atlas rasterization count around BOTH assemblies on the SAME
        // atlas: the same glyph shapes are reused, so no glyph re-rasterizes.
        let rasterizationsBefore = renderer.atlas.rasterizationCount
        let scene = ReferenceText.twoColorsScene(atlas: renderer.atlas)
        let rasterizationsAfter = renderer.atlas.rasterizationCount
        precondition(
            rasterizationsAfter == rasterizationsBefore,
            "two-colors: assembling the same glyphs twice must not re-rasterize "
                + "(before \(rasterizationsBefore), after \(rasterizationsAfter))"
        )

        let frame = renderer.captureSdfFrame(scene, width: referenceWidth, height: referenceHeight)
        SnapshotComparator.compareBgra(frame, goldenName: ReferenceText.twoColorsGoldenName)

        // Run A is the first half of the scene, run B the second; both are the same
        // string, so they have the same instance count and corresponding cells.
        let perRun = scene.count / 2
        precondition(perRun > 0, "two-colors: each run must have at least one glyph")
        let runA = Array(scene.prefix(perRun))
        let runB = Array(scene.suffix(perRun))

        // The SAME glyph shape drawn in two instance colors differs in RGB —
        // color-from-instance (Р8): the atlas carries coverage only.
        var foundDivergentCell = false
        for index in 0..<perRun {
            guard let strokeA = findStrokePixel(frame, inCellOf: runA[index]),
                  let strokeB = findStrokePixel(frame, inCellOf: runB[index]) else {
                continue
            }
            if rgbDiffers(strokeA, strokeB) {
                foundDivergentCell = true
                break
            }
        }
        precondition(
            foundDivergentCell,
            "two-colors: no cell where the two instance colors diverge in RGB — color not from instance"
        )
    }

    private static func runDrawCallMetric(_ renderer: Renderer) {
        SnapshotComparator.assertSingleDrawSingleCommit(
            renderer,
            scene: ReferenceText.mixedFrameScene(atlas: renderer.atlas),
            width: referenceWidth,
            height: referenceHeight
        )
    }

    // Scans the drawable-pixel cell of a glyph instance for the first pixel that
    // differs from the clear color by more than AA noise — a rendered stroke. The
    // cell is the instance's center +/- half its size, clamped to the frame.
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

    private static func rgbDiffers(
        _ first: (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8),
        _ second: (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8)
    ) -> Bool {
        channelDistance(first, second) > strokeChannelDelta
    }

    private static func premultipliedBytes(
        _ color: (r: Float, g: Float, b: Float, a: Float)
    ) -> (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8) {
        return (
            blue: channelToByte(color.b * color.a),
            green: channelToByte(color.g * color.a),
            red: channelToByte(color.r * color.a),
            alpha: channelToByte(color.a)
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
        assertEqualsBytes(rendered, expected: clearColorBytes(), label: label)
    }

    private static func assertEqualsPremultiplied(
        _ rendered: (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8),
        color: (r: Float, g: Float, b: Float, a: Float),
        label: String
    ) {
        assertEqualsBytes(rendered, expected: premultipliedBytes(color), label: label)
    }

    private static func assertEqualsBytes(
        _ rendered: (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8),
        expected: (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8),
        label: String
    ) {
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
