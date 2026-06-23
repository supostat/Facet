import CoreText
import Foundation

// End-to-end tests for the Ф14 UPWARD measure seam (Р10): the Zig core measure
// pass asks Swift to measure a text run with real Core Text and reads metrics back
// across the C-ABI boundary, cache-memoized so a repeated (string, width) HIT
// bypasses the seam. MEASURE-ONLY — Phase 14 is the measure seam alone; the
// rendering-half glyph injection is deferred to Phase 14b, so there are NO glyph
// pixels and NO measure-scene golden here (nothing legible renders without the
// deferred shaping). Each check is a deterministic DATA check at the seam end
// (spec §0a: seam phases use end-to-end tests with a data check at each end).
//
// The seam is driven directly through the C exports (not via Bridge, which is
// hardwired to the Phase-13 reference tree): create a handle, install the
// production facetMeasureText callback BEFORE the first produce (the install-order
// invariant), build the SEPARATE measure scene, set a stack instance buffer as the
// base, and produce — which runs the measure pass that crosses the seam.
@main
struct MeasureSeamEndToEndTests {
    static func main() {
        runSeamFidelity()
        runCrossingBypassedByCache()
        runFitContentGeometry()
        runEmptyStringIsZero()
        print("MeasureSeamEndToEndTests: all checks passed")
    }

    // (a) seam-fidelity: the main extent the Zig measure pass obtained through the
    // production callback equals an independent Swift Shaper.measure of the SAME
    // bytes + family + size. The callback and this assert call the identical Core
    // Text path, so they are equal by construction — asserted explicitly.
    private static func runSeamFidelity() {
        let handle = makeMeasureSeam()
        defer { facet_seam_destroy(handle) }
        let rootId = produceMeasureScene(handle)

        let labelContainerId = rootId + ReferenceZigTree.measureLabelContainerIdOffset
        let zigMeasuredMain = facet_seam_node_laid_out_main(handle, labelContainerId)

        let swiftMeasured = independentSwiftMeasure()
        precondition(
            abs(zigMeasuredMain - Float(swiftMeasured.main)) <= ReferenceZigTree.measureTolerance,
            "seam-fidelity: Zig-measured main \(zigMeasuredMain) != Swift Shaper.measure \(swiftMeasured.main)"
        )
        print("seam-fidelity: the Zig-measured main matches an independent Swift Core Text measure")
    }

    // (b) cache crossings: facet_seam_measure_crossings() == 1 after two produces of
    // the static measure scene — the second produce re-measures the identical
    // (string, width), an all-HIT that bypasses the seam (the anti-chatty-seam
    // guarantee, Р10/§4), so the counter does not increment past one.
    private static func runCrossingBypassedByCache() {
        let handle = makeMeasureSeam()
        defer { facet_seam_destroy(handle) }
        let rootId = produceMeasureScene(handle)

        var buffer = [FacetInstance](repeating: zeroInstance(), count: 16)
        buffer.withUnsafeMutableBufferPointer { pointer in
            _ = facet_seam_set_base_pointer(handle, pointer.baseAddress, UInt32(pointer.count))
            _ = facet_seam_give_instances(handle, rootId, Float(ReferenceZigTree.width), Float(ReferenceZigTree.height))
        }

        let crossings = facet_seam_measure_crossings(handle)
        precondition(crossings == 1, "cache crossings: expected exactly 1 seam crossing after two produces, got \(crossings)")
        print("cache crossings: the second produce was an all-cache-hit and did not re-cross the seam")
    }

    // (c) fit-content GEOMETRY: the laid-out container's resolved main extent equals
    // the real Core Text measured main — a DATA check via the laid-out rect through
    // facet_seam_node_laid_out_main, NOT a glyph pixel snapshot. The fit-content
    // container hugs the measured text, the SDF box the КТ-2 harness shows.
    private static func runFitContentGeometry() {
        let handle = makeMeasureSeam()
        defer { facet_seam_destroy(handle) }
        let rootId = produceMeasureScene(handle)

        let labelContainerId = rootId + ReferenceZigTree.measureLabelContainerIdOffset
        let containerMain = facet_seam_node_laid_out_main(handle, labelContainerId)

        let swiftMeasured = independentSwiftMeasure()
        precondition(
            abs(containerMain - Float(swiftMeasured.main)) <= ReferenceZigTree.measureTolerance,
            "fit-content geometry: container main \(containerMain) != measured text main \(swiftMeasured.main)"
        )
        precondition(containerMain > 0, "fit-content geometry: the container did not hug a positive measured width")
        print("fit-content geometry: the laid-out container hugs the real measured text width")
    }

    // (d) empty-string → {0, 0}: the production Core Text measure path returns zero
    // bounds for an empty string (no runs), the contract's empty-string result.
    private static func runEmptyStringIsZero() {
        let font = CTFontCreateWithName(
            ReferenceZigTree.measureFontName as CFString,
            ReferenceZigTree.measureFontSize,
            nil
        )
        let measured = Shaper.measure(string: "", font: font)
        precondition(measured.main == 0 && measured.cross == 0, "empty-string measure must be (0, 0), got \(measured)")
        print("empty-string: the measure of an empty string is (0, 0)")
    }

    // Creates a measure seam and installs the production Core Text callback BEFORE
    // any produce (the install-order invariant: a measure with a null slot is a
    // checked panic). The seam owns the SEPARATE measure scene, not the Phase-13
    // reference tree.
    private static func makeMeasureSeam() -> UnsafeMutableRawPointer {
        guard let handle = facet_seam_create() else {
            fatalError("facet_seam_create returned null (seam allocation failed)")
        }
        let status = facet_seam_set_measure_callback(handle, facetMeasureText)
        precondition(status == 0, "facet_seam_set_measure_callback rejected the production callback (status \(status))")
        return handle
    }

    // Builds the measure scene and produces it once into a stack instance buffer,
    // which runs the measure pass that crosses the seam, returning the root id.
    @discardableResult
    private static func produceMeasureScene(_ handle: UnsafeMutableRawPointer) -> UInt32 {
        let rootId = facet_seam_build_measure_tree(handle)
        precondition(rootId != UInt32.max, "facet_seam_build_measure_tree failed to build the measure scene")

        var buffer = [FacetInstance](repeating: zeroInstance(), count: 16)
        buffer.withUnsafeMutableBufferPointer { pointer in
            _ = facet_seam_set_base_pointer(handle, pointer.baseAddress, UInt32(pointer.count))
            let count = facet_seam_give_instances(handle, rootId, Float(ReferenceZigTree.width), Float(ReferenceZigTree.height))
            precondition(count >= 0, "the measure scene produce overflowed or failed (status \(count))")
        }
        return rootId
    }

    private static func independentSwiftMeasure() -> (main: CGFloat, cross: CGFloat) {
        let font = CTFontCreateWithName(
            ReferenceZigTree.measureFontName as CFString,
            ReferenceZigTree.measureFontSize,
            nil
        )
        return Shaper.measure(string: ReferenceZigTree.measureString, font: font)
    }

    private static func zeroInstance() -> FacetInstance {
        FacetInstance(
            positionX: 0, positionY: 0, width: 0, height: 0,
            colorR: 0, colorG: 0, colorB: 0, colorA: 0,
            cornerRadius: 0, type: 0,
            shadowOffsetX: 0, shadowOffsetY: 0, shadowBlurRadius: 0,
            shadowColorR: 0, shadowColorG: 0, shadowColorB: 0, shadowColorA: 0,
            borderThickness: 0,
            borderColorR: 0, borderColorG: 0, borderColorB: 0, borderColorA: 0,
            atlasMinU: 0, atlasMinV: 0, atlasMaxU: 0, atlasMaxV: 0
        )
    }
}
