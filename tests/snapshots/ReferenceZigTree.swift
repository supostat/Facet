import Foundation

// The single definition of the Zig-tree scene shared by the golden writer (the
// ZigTreeHarness --write-reference path) and the golden compare (the e2e test).
// Unlike Instance.referenceScene, this does NOT build any [Instance] in Swift: the
// scene IS the Zig `facet_seam_build_reference_tree`, and both the writer and the
// test drive that SAME Zig code through the seam, so the committed goldens and the
// test renders are byte-identical by construction.
//
// Because the golden is self-generated from the same code it pins, a golden cannot
// vouch for first-time correctness (a Y-flip would self-bake). Two guards close
// that: (1) the Zig scene is authored ASYMMETRIC across the horizontal midline —
// the top band and bottom band differ in color, radius, and vertical center; (2)
// the e2e test runs a golden-INDEPENDENT geometric spot-assert against the expected
// analytic colors below, sampling the top-band and bottom-band centers — so a
// whole-image flip the golden cannot catch is caught by the spot colors moving.
enum ReferenceZigTree {
    // The drawable the scene is laid out into (matches the Zig REFERENCE_WIDTH/
    // HEIGHT and the window content size).
    static let width = 1024
    static let height = 640

    static let beforeGoldenName = "phase-13-zig-tree.png"
    static let afterGoldenName = "phase-13-zig-tree-after-mutation.png"

    // The expected on-screen spot colors, kept in lock-step with the Zig
    // TOP_COLOR / BOTTOM_COLOR / MUTATED_TOP_COLOR constants (instance_seam.zig).
    // The fragment shader outputs premultiplied BGRA over the opaque clear; an
    // opaque fill (alpha 1) leaves rgb unchanged, so each straight-alpha channel
    // maps to round(channel * 255). These are NOT read from the golden — they are
    // the analytic ground truth a flipped frame would violate.
    struct SpotColor {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    // Top band: magenta (0.92, 0.20, 0.55). Center at (512, 160).
    static let topBandCenter = (x: 512, y: 160)
    static let topBandColor = SpotColor(red: 235, green: 51, blue: 140)

    // Bottom band: teal (0.10, 0.78, 0.74). Center at (512, 480).
    static let bottomBandCenter = (x: 512, y: 480)
    static let bottomBandColor = SpotColor(red: 26, green: 199, blue: 189)

    // After the paint mutation the top band recolors to (0.30, 0.55, 0.90); the
    // bottom band is untouched. The "next frame" test pins this against the
    // after-golden AND the spot color below.
    static let mutatedTopBandColor = SpotColor(red: 77, green: 140, blue: 230)

    // The per-channel tolerance the geometric spot-assert allows: anti-aliasing and
    // the float->byte round leave a band center exact, but the rounded-rect edges of
    // an adjacent band can bleed a step; a small slack keeps the assert robust while
    // still catching a whole-band color swap (which is dozens of steps off).
    static let spotTolerance: UInt8 = 3
}
