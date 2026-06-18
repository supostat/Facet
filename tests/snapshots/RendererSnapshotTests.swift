import Foundation

// Golden-PNG snapshot + metric test for the SDF renderer. Goldens are generated
// by `zig build bench -- --write-reference` and hand-committed; this test pins
// regressions against them. The comparison runs on PREMULTIPLIED BGRA bytes on
// both sides: the renderer's getBytes returns premultiplied data and PngImage
// reads/writes premultipliedFirst | byteOrder32Little, so no conversion is
// needed. Antialiased edges admit a small per-channel tolerance and a small
// fraction of mismatching pixels; the metric path is exact.
@main
struct RendererSnapshotTests {
    private static let referenceWidth = 1024
    private static let referenceHeight = 640

    // AA tolerance: a mismatching channel may differ by at most this many 1/255
    // steps, and at most this fraction of pixels may exceed it.
    private static let maxChannelDelta: UInt8 = 2
    private static let maxMismatchFraction = 0.005

    private static let goldensDirectory = "tests/snapshots"

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
        let drawsBefore = renderer.drawCallCount
        let commitsBefore = renderer.committedFrameCount
        _ = renderer.captureSdfFrame(
            Instance.referenceScene,
            width: referenceWidth,
            height: referenceHeight
        )
        let draws = renderer.drawCallCount - drawsBefore
        let commits = renderer.committedFrameCount - commitsBefore
        precondition(draws == 1, "expected exactly one draw call per frame, got \(draws)")
        precondition(commits == 1, "expected exactly one commit per frame, got \(commits)")
        print("draw_calls=\(draws) commits=\(commits)")
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
        let goldenURL = URL(fileURLWithPath: goldensDirectory).appendingPathComponent(goldenName)
        let golden = PngImage.read(url: goldenURL)

        precondition(
            golden.width == frame.width && golden.height == frame.height,
            "\(goldenName): size mismatch — golden \(golden.width)x\(golden.height), "
                + "rendered \(frame.width)x\(frame.height)"
        )
        precondition(
            golden.bgraPixels.count == frame.bgraPixels.count,
            "\(goldenName): byte-count mismatch"
        )

        var mismatchPixels = 0
        var maxObservedDelta: UInt8 = 0
        let pixelCount = frame.width * frame.height
        var byteOffset = 0
        while byteOffset < frame.bgraPixels.count {
            var pixelExceeds = false
            for channel in 0..<4 {
                let rendered = frame.bgraPixels[byteOffset + channel]
                let expected = golden.bgraPixels[byteOffset + channel]
                let delta = rendered > expected ? rendered - expected : expected - rendered
                maxObservedDelta = max(maxObservedDelta, delta)
                if delta > maxChannelDelta {
                    pixelExceeds = true
                }
            }
            if pixelExceeds {
                mismatchPixels += 1
            }
            byteOffset += 4
        }

        print("\(goldenName): mismatch_pixels=\(mismatchPixels) max_channel_delta=\(maxObservedDelta)")
        let mismatchFraction = Double(mismatchPixels) / Double(pixelCount)
        precondition(
            mismatchFraction <= maxMismatchFraction,
            "\(goldenName): \(mismatchPixels) of \(pixelCount) pixels exceed tolerance "
                + "(\(mismatchFraction) > \(maxMismatchFraction))"
        )
    }
}
