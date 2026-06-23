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

    // The Ф14 measure scene fixtures, kept in lock-step with the Zig
    // MEASURE_STRING / MEASURE_FONT_SIZE constants and the Shaper.measureFontName
    // (instance_seam.zig + Shaper.swift). The measure-only e2e measures the SAME
    // bytes + family + size through both the production seam callback and an
    // independent Swift Shaper.measure, so the two must agree by construction.
    static let measureString = "Facet"
    static let measureFontName = "Helvetica"
    static let measureFontSize: CGFloat = 32

    // The fit-content label container is the second node the Zig measure scene
    // creates (root id, then this container, then the text leaf), so its id is the
    // root id + 1. The geometry check reads its laid-out main extent (a row → the
    // rect width) back through facet_seam_node_laid_out_main.
    static let measureLabelContainerIdOffset: UInt32 = 1

    // The text leaf is the third node the Zig measure scene creates (root id, then
    // the label container, then the text leaf), so its id is the root id + 2. The
    // shape e2e reads its laid-out main back through facet_seam_node_laid_out_main to
    // assert the fit-content leaf ITSELF (not only the produced glyph suffix) was
    // measured to a non-zero text width.
    static let measureTextLeafIdOffset: UInt32 = 2

    // The float tolerance the seam-fidelity / geometry asserts allow: both sides
    // call the identical Core Text path so they agree to the bit, but a tiny slack
    // absorbs any Float<->CGFloat round without weakening the whole-measure check.
    static let measureTolerance: Float = 0.01

    // The Phase-14b shape↔measure agreement tolerance: the measured main
    // (CTLineGetTypographicBounds width) and the shaped line's total advance
    // ((last.origin.x − lineOrigin.x) + last.advance) can differ sub-pixel on
    // trailing whitespace, so the agreement check is a tolerance, NOT bit-equality.
    // "Facet" is whitespace-free so it holds tight; the slack keeps a future string
    // from making it flaky.
    static let shapeTolerance: Float = 0.5

    // The committed Phase-14b text-render golden, written by the КТ-2
    // --write-reference path (generated, not hand-authored). The scene is the
    // measure scene now rendering legible proportional Core Text.
    static let phase14bTextGoldenName = "phase-14b-text.png"
}
