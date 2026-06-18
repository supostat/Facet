import Foundation

// Golden-PNG snapshot + metric test for the SDF renderer. Goldens are generated
// by `zig build bench -- --write-reference` and hand-committed; this test pins
// regressions against them. The comparison runs on PREMULTIPLIED BGRA bytes on
// both sides: the renderer's getBytes returns premultiplied data and PngImage
// reads/writes premultipliedFirst | byteOrder32Little, so no conversion is
// needed. Antialiased edges admit a small per-channel tolerance and a small
// fraction of mismatching pixels; the metric path is exact. The compare loop,
// tolerances, and draw-call metric live in the shared SnapshotComparator.
@main
struct RendererSnapshotTests {
    private static let referenceWidth = 1024
    private static let referenceHeight = 640

    static func main() {
        let renderer = Renderer(metallibPath: MetallibLocator.resolve())
        runHappyReferenceCase(renderer)
        runDrawCallMetric(renderer)
        runRadiusZeroEdgeCase(renderer)
        runRadiusHalfSideEdgeCase(renderer)
    }

    private static func runHappyReferenceCase(_ renderer: Renderer) {
        compareAgainstGolden(
            renderer,
            scene: Instance.referenceScene,
            goldenName: "sdf_reference_rects.png"
        )
    }

    private static func runRadiusZeroEdgeCase(_ renderer: Renderer) {
        compareAgainstGolden(
            renderer,
            scene: Instance.radiusZeroScene,
            goldenName: "sdf_radius_zero.png"
        )
    }

    private static func runRadiusHalfSideEdgeCase(_ renderer: Renderer) {
        compareAgainstGolden(
            renderer,
            scene: Instance.radiusHalfSideScene,
            goldenName: "sdf_radius_half_side.png"
        )
    }

    private static func runDrawCallMetric(_ renderer: Renderer) {
        SnapshotComparator.assertSingleDrawSingleCommit(
            renderer,
            scene: Instance.referenceScene,
            width: referenceWidth,
            height: referenceHeight
        )
    }

    private static func compareAgainstGolden(
        _ renderer: Renderer,
        scene: [Instance],
        goldenName: String
    ) {
        let frame = renderer.captureSdfFrame(
            scene,
            width: referenceWidth,
            height: referenceHeight
        )
        SnapshotComparator.compareBgra(frame, goldenName: goldenName)
    }
}
