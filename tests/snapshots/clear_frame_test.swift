import Foundation
import Metal

// Snapshot + metric test for the Phase 1 clear-frame path.
// No reference PNG: a clear pass with a known clearColor is fully reproducible,
// so we assert directly against the exact clearColor BGRA8 bytes. The offscreen
// texture has no colorspace and lives in shared storage on unified memory, so
// getBytes returns the bytes Metal wrote with no colormatch (unlike a live layer).

func expectedClearBytes() -> (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8) {
    let color = Renderer.clearColor
    return (
        blue: channelToByte(color.blue),
        green: channelToByte(color.green),
        red: channelToByte(color.red),
        alpha: channelToByte(color.alpha)
    )
}

func channelToByte(_ component: Double) -> UInt8 {
    UInt8((component * 255.0).rounded())
}

@main
struct ClearFrameTest {
    static func main() {
        let renderer = Renderer()
        runHappySquareCase(renderer)
        runNonSquareEdgeCase(renderer)
        runSingleCommitMetric(renderer)
    }
}

func assertEveryPixelIsClearColor(_ frame: CapturedFrame) {
    let expected = expectedClearBytes()
    let pixelCount = frame.width * frame.height
    precondition(
        frame.bgraPixels.count == pixelCount * 4,
        "stride mismatch: expected \(pixelCount * 4) bytes, got \(frame.bgraPixels.count)"
    )
    var offset = 0
    while offset < frame.bgraPixels.count {
        precondition(frame.bgraPixels[offset] == expected.blue, "blue mismatch at byte \(offset)")
        precondition(frame.bgraPixels[offset + 1] == expected.green, "green mismatch at byte \(offset)")
        precondition(frame.bgraPixels[offset + 2] == expected.red, "red mismatch at byte \(offset)")
        precondition(frame.bgraPixels[offset + 3] == expected.alpha, "alpha mismatch at byte \(offset)")
        offset += 4
    }
}

func runHappySquareCase(_ renderer: Renderer) {
    let frame = renderer.captureClearFrame(width: 512, height: 512)
    assertEveryPixelIsClearColor(frame)
}

func runNonSquareEdgeCase(_ renderer: Renderer) {
    let frame = renderer.captureClearFrame(width: 1024, height: 300)
    precondition(frame.width == 1024, "width not honored")
    precondition(frame.height == 300, "height not honored")
    assertEveryPixelIsClearColor(frame)
}

func runSingleCommitMetric(_ renderer: Renderer) {
    let before = renderer.committedFrameCount
    _ = renderer.captureClearFrame(width: 64, height: 64)
    let committedThisFrame = renderer.committedFrameCount - before
    precondition(committedThisFrame == 1, "expected exactly one commit per frame, got \(committedThisFrame)")
    print("commits=\(committedThisFrame)")
}
