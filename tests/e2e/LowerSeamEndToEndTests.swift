import Foundation

// End-to-end tests for the Р13 lower seam: the Zig core writes the instance array
// straight into the renderer's StorageModeShared MTLBuffer (zero-copy via unified
// memory), Swift binds the SAME buffer, and the frame renders. These are the
// integration-seam tests for the most dangerous two-language boundary (spec §0a:
// seam phases use end-to-end tests with a deterministic data check at each end).
//
// The goldens (phase-13-zig-tree.png / -after-mutation.png) are written by
// ZigTreeHarness --write-reference from the SAME Zig build_reference_tree this test
// drives, so a golden compare alone is self-referential. Two guards make it
// meaningful: the Zig scene is asymmetric across the horizontal midline, and test 8
// runs a golden-INDEPENDENT geometric spot-assert against the analytic band colors.
@main
struct LowerSeamEndToEndTests {
    static func main() {
        runSameBytesAcrossTheSeam()
        runNoCopyPointerIdentity()
        runEndToEndSnapshot()
        runNextFrameMutationSnapshot()
        runFrameStatsDeterminismAndSpotAssert()
        runUnderCapacityGrowAndRehand()
        print("LowerSeamEndToEndTests: all checks passed")
    }

    // Test 4 — same bytes across the seam: after a produce, the bytes the Zig seam
    // wrote at the shared-buffer base read back field-for-field as the reference
    // tree's instances through the C FacetInstance view.
    private static func runSameBytesAcrossTheSeam() {
        let renderer = Renderer(metallibPath: MetallibLocator.resolve())
        let bridge = Bridge(renderer: renderer)

        let count = bridge.produceInstances(
            drawableWidth: Float(ReferenceZigTree.width),
            drawableHeight: Float(ReferenceZigTree.height)
        )
        precondition(count == 3, "reference tree should emit 3 instances, got \(count)")

        let base = renderer.sharedInstanceBufferBaseAddress.assumingMemoryBound(to: FacetInstance.self)
        // Slot 1 is the magenta top band: full width, top-half height, center at
        // (512, 160), magenta straight-alpha color, SDF type 0.
        let top = base[1]
        precondition(top.type == 0, "top band must be an SDF instance, got type \(top.type)")
        precondition(top.width == Float(ReferenceZigTree.width), "top band width mismatch: \(top.width)")
        precondition(top.height == Float(ReferenceZigTree.height) / 2, "top band height mismatch: \(top.height)")
        precondition(top.positionX == Float(ReferenceZigTree.width) / 2, "top band center x mismatch: \(top.positionX)")
        precondition(top.positionY == Float(ReferenceZigTree.height) / 4, "top band center y mismatch: \(top.positionY)")
        precondition(abs(top.colorR - 0.92) < 0.0001, "top band red mismatch: \(top.colorR)")
        precondition(abs(top.colorG - 0.20) < 0.0001, "top band green mismatch: \(top.colorG)")
        precondition(abs(top.colorB - 0.55) < 0.0001, "top band blue mismatch: \(top.colorB)")
        print("same-bytes: top-band FacetInstance read back field-for-field")
    }

    // Test 7 — no-copy pointer identity: the base address handed to Zig is the SAME
    // address the Renderer binds at setVertexBuffer, so Metal reads exactly the
    // bytes Zig wrote with no intervening copy. The address is stable across a
    // produce that does not grow.
    private static func runNoCopyPointerIdentity() {
        let renderer = Renderer(metallibPath: MetallibLocator.resolve())
        let baseBeforeBridge = renderer.sharedInstanceBufferBaseAddress

        let bridge = Bridge(renderer: renderer)
        // Bridge handed exactly this base to the seam at init; it has not grown.
        let baseAfterInit = renderer.sharedInstanceBufferBaseAddress
        precondition(baseBeforeBridge == baseAfterInit, "the shared base moved during seam init without a grow")

        _ = bridge.produceInstances(
            drawableWidth: Float(ReferenceZigTree.width),
            drawableHeight: Float(ReferenceZigTree.height)
        )
        let baseAfterProduce = renderer.sharedInstanceBufferBaseAddress
        precondition(
            baseAfterInit == baseAfterProduce,
            "the produce moved the shared base without a grow — the no-copy identity broke"
        )
        print("no-copy: the seam wrote into the same base the renderer binds")
    }

    // Test 5 — end-to-end snapshot: drive the Zig tree through the seam into the
    // shared buffer and render it, comparing against the committed before-golden.
    private static func runEndToEndSnapshot() {
        let renderer = Renderer(metallibPath: MetallibLocator.resolve())
        let bridge = Bridge(renderer: renderer)

        let frame = produceAndCapture(renderer: renderer, bridge: bridge)
        SnapshotComparator.compareBgra(frame, goldenName: ReferenceZigTree.beforeGoldenName)
    }

    // Test 6 — next frame reflects a mutation: mutate the reference tree, re-produce,
    // and compare against the after-golden. The has-changed gate reports the change.
    private static func runNextFrameMutationSnapshot() {
        let renderer = Renderer(metallibPath: MetallibLocator.resolve())
        let bridge = Bridge(renderer: renderer)

        _ = produceAndCapture(renderer: renderer, bridge: bridge)
        precondition(!bridge.hasChanged(), "a static frame after a produce must report no change")

        bridge.mutate()
        precondition(bridge.hasChanged(), "a mutation must make the next frame a change")
        let frame = produceAndCapture(renderer: renderer, bridge: bridge)
        SnapshotComparator.compareBgra(frame, goldenName: ReferenceZigTree.afterGoldenName)
        assertSpot(frame, at: ReferenceZigTree.topBandCenter, expect: ReferenceZigTree.mutatedTopBandColor, label: "mutated top band")
    }

    // Test 8 — frame-stats determinism + the golden-INDEPENDENT geometric spot
    // assert: two static produce runs recompute zero nodes and yield byte-identical
    // counts, and the rendered top/bottom band centers carry the analytic band
    // colors (a whole-image flip a self-referential golden cannot catch moves these).
    private static func runFrameStatsDeterminismAndSpotAssert() {
        let renderer = Renderer(metallibPath: MetallibLocator.resolve())
        let bridge = Bridge(renderer: renderer)

        let frame = produceAndCapture(renderer: renderer, bridge: bridge)
        let firstCount = bridge.lastInstanceCount

        // A second produce on the unchanged tree recomputes nothing and matches.
        let secondCount = bridge.produceInstances(
            drawableWidth: Float(ReferenceZigTree.width),
            drawableHeight: Float(ReferenceZigTree.height)
        )
        precondition(firstCount == secondCount, "static produce instance count drifted: \(firstCount) vs \(secondCount)")
        precondition(
            bridge.lastRecomputedNodeCount == 0,
            "a static frame must recompute zero nodes, got \(bridge.lastRecomputedNodeCount)"
        )

        assertSpot(frame, at: ReferenceZigTree.topBandCenter, expect: ReferenceZigTree.topBandColor, label: "top band")
        assertSpot(frame, at: ReferenceZigTree.bottomBandCenter, expect: ReferenceZigTree.bottomBandColor, label: "bottom band")
        print("frame-stats: deterministic counts and the band spot colors hold")
    }

    // Error path — under-capacity grow-and-rehand: a renderer whose shared buffer
    // cannot hold the tree forces the seam to report overflow; the Bridge grows the
    // buffer 2x, re-hands the new base, and retries, so the frame still renders
    // correctly against the before-golden.
    private static func runUnderCapacityGrowAndRehand() {
        // Start the shared buffer below the tree's 3 instances so the first produce
        // overflows and must grow (the production minimum is 16, so 2 forces it).
        let renderer = Renderer(metallibPath: MetallibLocator.resolve(), initialInstanceCapacity: 2)
        let bridge = Bridge(renderer: renderer)

        let count = bridge.produceInstances(
            drawableWidth: Float(ReferenceZigTree.width),
            drawableHeight: Float(ReferenceZigTree.height)
        )
        precondition(count == 3, "after grow-and-rehand the tree should still emit 3 instances, got \(count)")
        precondition(
            renderer.sharedInstanceCapacity >= 3,
            "the shared buffer should have grown to fit, capacity \(renderer.sharedInstanceCapacity)"
        )

        let frame = renderer.captureSdfFrame(
            instanceCount: count,
            width: ReferenceZigTree.width,
            height: ReferenceZigTree.height
        )
        SnapshotComparator.compareBgra(frame, goldenName: ReferenceZigTree.beforeGoldenName)
        assertSpot(frame, at: ReferenceZigTree.topBandCenter, expect: ReferenceZigTree.topBandColor, label: "top band after grow")
        print("grow-and-rehand: the frame renders correctly after the buffer grew")
    }

    private static func produceAndCapture(renderer: Renderer, bridge: Bridge) -> CapturedFrame {
        let count = bridge.produceInstances(
            drawableWidth: Float(ReferenceZigTree.width),
            drawableHeight: Float(ReferenceZigTree.height)
        )
        return renderer.captureSdfFrame(
            instanceCount: count,
            width: ReferenceZigTree.width,
            height: ReferenceZigTree.height
        )
    }

    private static func assertSpot(
        _ frame: CapturedFrame,
        at point: (x: Int, y: Int),
        expect: ReferenceZigTree.SpotColor,
        label: String
    ) {
        let pixel = SnapshotComparator.pixel(frame, point.x, point.y)
        let tolerance = ReferenceZigTree.spotTolerance
        precondition(within(pixel.red, expect.red, tolerance), "\(label) red \(pixel.red) != \(expect.red)")
        precondition(within(pixel.green, expect.green, tolerance), "\(label) green \(pixel.green) != \(expect.green)")
        precondition(within(pixel.blue, expect.blue, tolerance), "\(label) blue \(pixel.blue) != \(expect.blue)")
    }

    private static func within(_ actual: UInt8, _ expected: UInt8, _ tolerance: UInt8) -> Bool {
        let delta = actual > expected ? actual - expected : expected - actual
        return delta <= tolerance
    }
}
