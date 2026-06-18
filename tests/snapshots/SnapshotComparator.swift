import Foundation

// Shared golden-PNG compare for the snapshot test suite. Extracted verbatim from
// the per-test compareAgainstGolden duplicated across RendererSnapshotTests and
// Phase3ShadowBorderTests: the same AA-tolerant per-pixel loop, the same
// tolerance constants, the same pixel accessor, and the same one-draw/one-commit
// metric assert. The compare returns the rendered CapturedFrame so a caller can
// run further analytic spot-asserts on the exact bytes the golden validated
// (Phase 3 consumes the return; the SDF suite ignores it). Test-only: any
// failure is a hard precondition/fatalError.
//
// The comparison runs on PREMULTIPLIED bytes on both sides: the renderer's
// getBytes returns premultiplied data and PngImage reads/writes
// premultipliedFirst | byteOrder32Little (BGRA) for compareBgra, while the R8
// atlas dump and its deviceGray PNG are single-channel for compareGray. Both use
// the same channel-delta + mismatch-fraction tolerances.
enum SnapshotComparator {
    // AA tolerance: a mismatching channel may differ by at most this many 1/255
    // steps, and at most this fraction of pixels may exceed it.
    static let maxChannelDelta: UInt8 = 2
    static let maxMismatchFraction = 0.005

    static let goldensDirectory = "tests/snapshots"

    // Compares a rendered BGRA frame against a committed BGRA golden PNG and
    // returns the frame so the caller can run analytic spot-asserts on the same
    // bytes. The four BGRA channels are compared per pixel.
    @discardableResult
    static func compareBgra(_ frame: CapturedFrame, goldenName: String) -> CapturedFrame {
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
        return frame
    }

    // Single-channel variant for the R8 atlas dump: one byte per pixel, same
    // delta + mismatch-fraction tolerances as the BGRA path. grayPixels is the
    // rendered R8 readback in top-left atlas space; the golden PNG is the
    // deviceGray export of the same texture.
    static func compareGray(
        grayPixels: [UInt8],
        width: Int,
        height: Int,
        goldenName: String
    ) {
        let goldenURL = URL(fileURLWithPath: goldensDirectory).appendingPathComponent(goldenName)
        let golden = PngImage.readGray(url: goldenURL)

        precondition(
            golden.width == width && golden.height == height,
            "\(goldenName): size mismatch — golden \(golden.width)x\(golden.height), "
                + "rendered \(width)x\(height)"
        )
        precondition(
            golden.grayPixels.count == grayPixels.count,
            "\(goldenName): byte-count mismatch — golden \(golden.grayPixels.count), "
                + "rendered \(grayPixels.count)"
        )

        var mismatchPixels = 0
        var maxObservedDelta: UInt8 = 0
        let pixelCount = width * height
        for index in 0..<grayPixels.count {
            let rendered = grayPixels[index]
            let expected = golden.grayPixels[index]
            let delta = rendered > expected ? rendered - expected : expected - rendered
            maxObservedDelta = max(maxObservedDelta, delta)
            if delta > maxChannelDelta {
                mismatchPixels += 1
            }
        }

        print("\(goldenName): mismatch_pixels=\(mismatchPixels) max_channel_delta=\(maxObservedDelta)")
        let mismatchFraction = Double(mismatchPixels) / Double(pixelCount)
        precondition(
            mismatchFraction <= maxMismatchFraction,
            "\(goldenName): \(mismatchPixels) of \(pixelCount) pixels exceed tolerance "
                + "(\(mismatchFraction) > \(maxMismatchFraction))"
        )
    }

    // BGRA pixel accessor shared by the analytic spot-asserts.
    static func pixel(
        _ frame: CapturedFrame,
        _ x: Int,
        _ y: Int
    ) -> (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8) {
        let byteOffset = (y * frame.width + x) * 4
        return (
            blue: frame.bgraPixels[byteOffset],
            green: frame.bgraPixels[byteOffset + 1],
            red: frame.bgraPixels[byteOffset + 2],
            alpha: frame.bgraPixels[byteOffset + 3]
        )
    }

    // One-draw/one-commit metric: every drawn frame advances drawCallCount and
    // committedFrameCount by exactly one.
    static func assertSingleDrawSingleCommit(
        _ renderer: Renderer,
        scene: [Instance],
        width: Int,
        height: Int
    ) {
        let drawsBefore = renderer.drawCallCount
        let commitsBefore = renderer.committedFrameCount
        _ = renderer.captureSdfFrame(scene, width: width, height: height)
        let draws = renderer.drawCallCount - drawsBefore
        let commits = renderer.committedFrameCount - commitsBefore
        precondition(draws == 1, "expected exactly one draw call per frame, got \(draws)")
        precondition(commits == 1, "expected exactly one commit per frame, got \(commits)")
        print("draw_calls=\(draws) commits=\(commits)")
    }
}
