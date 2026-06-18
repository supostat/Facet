import Foundation

// Golden-PNG snapshot + analytic spot-assert test for the Phase 3 SDF path:
// soft analytic drop shadow + border composited shadow->fill->border inside the
// single sdf_fragment, still ONE instanced draw call. The golden compares mirror
// RendererSnapshotTests (premultiplied BGRA on both sides, AA tolerance). The
// analytic spot-asserts are golden-INDEPENDENT: they pin specific pixels to
// values derived from the analytic shadow/border math, so they genuinely fail
// when the shader has not implemented the effect — the goldens cannot vouch for
// themselves. EXACT asserts pin coverage in {0,1}; RANGED asserts bound a
// fractional coverage value.
@main
struct Phase3ShadowBorderTests {
    private static let referenceWidth = 1024
    private static let referenceHeight = 640

    // Interior (non-edge) EXACT asserts may absorb at most this much FP rounding.
    // The AA-tolerant golden compare lives in SnapshotComparator; this is the
    // tighter tolerance for the analytic spot-asserts.
    private static let exactInteriorTolerance: UInt8 = 2

    static func main() {
        let renderer = Renderer(metallibPath: MetallibLocator.resolve())
        runShadowCase(renderer)
        runBorderCase(renderer)
        runCombinedCase(renderer)
        runDrawCallMetric(renderer)
    }

    private static func runShadowCase(_ renderer: Renderer) {
        let frame = compareAgainstGolden(
            renderer,
            scene: Instance.shadowScene,
            goldenName: "phase-3-shadow.png"
        )

        // The drop shadow composites OVER the opaque clear color, so the blend's
        // .one/.oneMinusSourceAlpha alpha factor pins the framebuffer alpha to 255
        // everywhere — the shadow is carried in the RGB channels, not alpha. A
        // black shadow (shadowColor.rgb == 0) darkens the clear toward black:
        // final.rgb == clear.rgb * (1 - shadowAlpha). shadowStrength measures that
        // darkening on the blue channel (the largest, so the most resolution).
        let clearBlue = channelToByte(Float(Renderer.clearColor.blue))
        func shadowStrength(_ x: Int, _ y: Int) -> Int {
            Int(clearBlue) - Int(pixel(frame, x, y).blue)
        }
        // Peak strength at shadowColor.a == 0.6: clear.b - clear.b*(1-0.6).
        let peakStrength = Int(clearBlue) - Int(channelToByte(Float(Renderer.clearColor.blue) * 0.4))

        // (1) RANGED: outside the body, inside the offset+blur extent — a soft
        // shadow pixel darker than clear but lighter than the full-strength peak.
        let soft = shadowStrength(704, 442)
        precondition(
            soft > 0 && soft < peakStrength,
            "shadow(1): expected soft shadow strength in (0, \(peakStrength)), got \(soft)"
        )

        // (2) EXACT: shadowDistance = +34 > blur 28 -> coverage 0 -> clearColor.
        assertEqualsClearColor(pixel(frame, 750, 320), label: "shadow(2)")

        // (3) EXACT: deep inside the opaque fill -> alpha 255, premultiplied
        // opaque fill; the shadow does NOT show through the opaque body.
        let lightFill: (r: Float, g: Float, b: Float, a: Float) = (0.85, 0.85, 0.88, 1.0)
        let center = pixel(frame, 512, 320)
        precondition(center.alpha == 255, "shadow(3): expected opaque center alpha 255, got \(center.alpha)")
        assertEqualsPremultiplied(center, color: lightFill, label: "shadow(3)")

        // (4) RANGED: monotonic soft falloff along the shadow's blurred edge —
        // three pinned points with strictly decreasing shadow strength.
        let near = shadowStrength(700, 438)
        let mid = shadowStrength(708, 446)
        let far = shadowStrength(716, 454)
        precondition(
            near > mid && mid > far,
            "shadow(4): expected strictly decreasing shadow falloff, got \(near) > \(mid) > \(far)"
        )
    }

    private static func runBorderCase(_ renderer: Renderer) {
        let frame = compareAgainstGolden(
            renderer,
            scene: Instance.borderScene,
            goldenName: "phase-3-border.png"
        )

        let opaqueWhite: (r: Float, g: Float, b: Float, a: Float) = (1.0, 1.0, 1.0, 1.0)
        let blueFill: (r: Float, g: Float, b: Float, a: Float) = (0.20, 0.55, 0.95, 1.0)

        // (1) EXACT: 8px inside the right edge, within the 16px border band ->
        // premultiplied opaque white.
        assertEqualsPremultiplied(pixel(frame, 684, 320), color: opaqueWhite, label: "border(1)")

        // (2) EXACT: well inside the inner edge -> premultiplied blue fill.
        assertEqualsPremultiplied(pixel(frame, 668, 320), color: blueFill, label: "border(2)")

        // (3) EXACT: outside the body -> clearColor.
        assertEqualsClearColor(pixel(frame, 702, 320), label: "border(3)")
    }

    private static func runCombinedCase(_ renderer: Renderer) {
        let frame = compareAgainstGolden(
            renderer,
            scene: Instance.combinedScene,
            goldenName: "phase-3-combined.png"
        )

        // A pixel within the border band resolves to premultiplied white: the
        // border draws on top and the opaque body occludes the shadow there.
        let opaqueWhite: (r: Float, g: Float, b: Float, a: Float) = (1.0, 1.0, 1.0, 1.0)
        assertEqualsPremultiplied(pixel(frame, 684, 320), color: opaqueWhite, label: "combined")
    }

    private static func runDrawCallMetric(_ renderer: Renderer) {
        SnapshotComparator.assertSingleDrawSingleCommit(
            renderer,
            scene: Instance.combinedScene,
            width: referenceWidth,
            height: referenceHeight
        )
    }

    // Returns the rendered frame so the caller can run analytic spot-asserts on
    // the same bytes the golden compare validated.
    @discardableResult
    private static func compareAgainstGolden(
        _ renderer: Renderer,
        scene: [Instance],
        goldenName: String
    ) -> CapturedFrame {
        let frame = renderer.captureSdfFrame(
            scene,
            width: referenceWidth,
            height: referenceHeight
        )
        return SnapshotComparator.compareBgra(frame, goldenName: goldenName)
    }

    private static func pixel(
        _ frame: CapturedFrame,
        _ x: Int,
        _ y: Int
    ) -> (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8) {
        SnapshotComparator.pixel(frame, x, y)
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

    private static func assertEqualsPremultiplied(
        _ rendered: (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8),
        color: (r: Float, g: Float, b: Float, a: Float),
        label: String
    ) {
        assertEqualsBytes(rendered, expected: premultipliedBytes(color), label: label)
    }

    private static func assertEqualsClearColor(
        _ rendered: (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8),
        label: String
    ) {
        let clear = Renderer.clearColor
        let expected: (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8) = (
            blue: channelToByte(Float(clear.blue)),
            green: channelToByte(Float(clear.green)),
            red: channelToByte(Float(clear.red)),
            alpha: channelToByte(Float(clear.alpha))
        )
        assertEqualsBytes(rendered, expected: expected, label: label)
    }

    private static func assertEqualsBytes(
        _ rendered: (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8),
        expected: (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8),
        label: String
    ) {
        precondition(
            channelWithin(rendered.blue, expected.blue),
            "\(label): blue \(rendered.blue) != \(expected.blue)"
        )
        precondition(
            channelWithin(rendered.green, expected.green),
            "\(label): green \(rendered.green) != \(expected.green)"
        )
        precondition(
            channelWithin(rendered.red, expected.red),
            "\(label): red \(rendered.red) != \(expected.red)"
        )
        precondition(
            channelWithin(rendered.alpha, expected.alpha),
            "\(label): alpha \(rendered.alpha) != \(expected.alpha)"
        )
    }

    private static func channelWithin(_ rendered: UInt8, _ expected: UInt8) -> Bool {
        let delta = rendered > expected ? rendered - expected : expected - rendered
        return delta <= exactInteriorTolerance
    }
}
