import CoreText
import Foundation

// End-to-end tests for the Phase-14b UPWARD shape seam (Р10): after the Zig core
// measure + place passes size and position a fit-content text leaf, the shape pass
// asks Swift to shape the string with real Core Text into per-glyph geometry, copies
// it into the tree arena onto node.placed_glyphs, and the existing instances.zig
// type==1u path renders legible kerned glyphs through the Phase-13 lower seam. The
// committed golden is a "whole-image shape" so it is PAIRED with golden-INDEPENDENT
// geometric asserts (the 2026-06-21 upside-down-glyph lesson — a self-referential
// text golden cannot vouch for orientation) plus a measure↔shape agreement check.
//
// The seam is driven directly through the C exports (not via Bridge, which is
// hardwired to the Phase-13 reference tree): create a handle, install the production
// measure + shape callbacks BEFORE the first produce (the install-order invariant),
// build the SEPARATE measure scene, hand the renderer's shared buffer as the base,
// and produce — which runs the measure pass AND the shape pass that crosses up.
@main
struct ShapeSeamEndToEndTests {
    static func main() {
        runReferenceGolden()
        runGlyphGeometryIsLegibleAndOriented()
        runMeasureShapeAgreement()
        runStaticReShapeGate()
        print("ShapeSeamEndToEndTests: all checks passed")
    }

    // (a) the rendered fit-content text frame matches the committed Phase-14b golden
    // within AA tolerance. The golden is written by the КТ-2 --write-reference path
    // from the SAME Zig measure scene this drives, so it is self-referential — the
    // golden-independent asserts below close that gap.
    private static func runReferenceGolden() {
        let renderer = Renderer(metallibPath: MetallibLocator.resolve())
        let scene = produceMeasureScene(renderer: renderer)
        defer { facet_seam_destroy(scene.handle) }

        let frame = renderer.captureSdfFrame(
            instanceCount: scene.instanceCount,
            width: ReferenceZigTree.width,
            height: ReferenceZigTree.height
        )
        SnapshotComparator.compareBgra(frame, goldenName: ReferenceZigTree.phase14bTextGoldenName)
    }

    // (b) golden-INDEPENDENT geometry: every text glyph instance carries the glyph
    // type, the five "Facet" glyph centers strictly increase along the line (no fixed
    // pen / overlap / flip in X), and an actual rendered stroke sits inside the first
    // glyph's cell (the glyphs draw ink where the geometry says, not above the box).
    private static func runGlyphGeometryIsLegibleAndOriented() {
        let renderer = Renderer(metallibPath: MetallibLocator.resolve())
        let scene = produceMeasureScene(renderer: renderer)
        defer { facet_seam_destroy(scene.handle) }

        let glyphInstances = readGlyphInstances(renderer: renderer, scene: scene)
        precondition(
            glyphInstances.count == ReferenceZigTree.measureString.count,
            "shape geometry: expected \(ReferenceZigTree.measureString.count) glyph instances, got \(glyphInstances.count)"
        )

        for glyph in glyphInstances {
            precondition(glyph.type == glyphInstanceType, "shape geometry: a text instance must be a glyph, got type \(glyph.type)")
        }
        for index in 1..<glyphInstances.count {
            precondition(
                glyphInstances[index].positionX > glyphInstances[index - 1].positionX,
                "shape geometry: glyph centers must strictly increase, "
                    + "x[\(index)]=\(glyphInstances[index].positionX) <= x[\(index - 1)]=\(glyphInstances[index - 1].positionX)"
            )
        }

        let frame = renderer.captureSdfFrame(
            instanceCount: scene.instanceCount,
            width: ReferenceZigTree.width,
            height: ReferenceZigTree.height
        )
        let strokePixel = findStrokePixel(frame, inCellOf: glyphInstances[0])
        precondition(strokePixel != nil, "shape geometry: no glyph stroke found in the first cell — text not rendered legibly")
        print("shape geometry: \(glyphInstances.count) glyphs, strictly-increasing centers, ink inside the first cell")
    }

    // (c) measure↔shape agreement WITH TOLERANCE: the shaped line's total advance
    // ((last.origin.x − lineOrigin.x) + last.advance, the Ф6 ShaperSnapshotTests
    // formula) equals the laid-out container's resolved main AND the Phase-14
    // measured main within ReferenceZigTree.shapeTolerance — NOT bit-equality (they
    // can differ sub-pixel on trailing whitespace; "Facet" is whitespace-free).
    private static func runMeasureShapeAgreement() {
        let renderer = Renderer(metallibPath: MetallibLocator.resolve())
        let scene = produceMeasureScene(renderer: renderer)
        defer { facet_seam_destroy(scene.handle) }

        let containerId = scene.rootId + ReferenceZigTree.measureLabelContainerIdOffset
        let containerMain = facet_seam_node_laid_out_main(scene.handle, containerId)
        let textLeafId = scene.rootId + ReferenceZigTree.measureTextLeafIdOffset
        let textLeafMain = facet_seam_node_laid_out_main(scene.handle, textLeafId)

        let font = referenceFont()
        let measured = Shaper.measure(string: ReferenceZigTree.measureString, font: font)
        let shapedAdvance = independentShapedAdvance(font: font)

        precondition(
            abs(shapedAdvance - Float(measured.main)) <= ReferenceZigTree.shapeTolerance,
            "measure↔shape: shaped advance \(shapedAdvance) != measured main \(measured.main) within \(ReferenceZigTree.shapeTolerance)"
        )
        precondition(
            abs(containerMain - Float(measured.main)) <= ReferenceZigTree.shapeTolerance,
            "measure↔shape: container main \(containerMain) != measured main \(measured.main) within \(ReferenceZigTree.shapeTolerance)"
        )
        // The fit-content text leaf ITSELF (looked up by root + measureTextLeafIdOffset,
        // not the produced glyph suffix) was measured to the same non-zero text width,
        // so the by-id read confirms the leaf node — not just the buffer tail — shaped.
        precondition(
            abs(textLeafMain - Float(measured.main)) <= ReferenceZigTree.shapeTolerance,
            "measure↔shape: text-leaf main \(textLeafMain) != measured main \(measured.main) within \(ReferenceZigTree.shapeTolerance)"
        )
        print("measure↔shape: text-leaf main == container main == measured main == shaped advance within tolerance")
    }

    // (d) a static second produce re-shapes nothing: the text leaf stays shape_cross,
    // so facet_seam_shape_crossings == 1 across two produces (the anti-chatty shape
    // seam, the rendering half of the Р10 §4 invariant).
    private static func runStaticReShapeGate() {
        let renderer = Renderer(metallibPath: MetallibLocator.resolve())
        let scene = produceMeasureScene(renderer: renderer)
        defer { facet_seam_destroy(scene.handle) }

        let base = renderer.sharedInstanceBufferBaseAddress.assumingMemoryBound(to: FacetInstance.self)
        _ = facet_seam_set_base_pointer(scene.handle, base, UInt32(renderer.sharedInstanceCapacity))
        _ = facet_seam_give_instances(scene.handle, scene.rootId, Float(ReferenceZigTree.width), Float(ReferenceZigTree.height))

        let crossings = facet_seam_shape_crossings(scene.handle)
        precondition(crossings == 1, "static re-shape: expected exactly 1 shape crossing after two produces, got \(crossings)")
        print("static re-shape: the second produce reused the arena glyphs and did not re-cross the seam")
    }

    // The driven measure scene: the seam handle, its root id, and the produced
    // instance count in the renderer's shared buffer (2 SDF + N glyphs).
    private struct DrivenMeasureScene {
        let handle: UnsafeMutableRawPointer
        let rootId: UInt32
        let instanceCount: Int
    }

    // Creates a seam, installs the production measure + shape callbacks BEFORE any
    // produce (the install-order invariant), builds the measure scene, and produces
    // it once into the renderer's shared buffer (which measures AND shapes the leaf).
    // The shape callback reads the renderer's live Atlas via makeFacetShapeText.
    private static func produceMeasureScene(renderer: Renderer) -> DrivenMeasureScene {
        guard let handle = facet_seam_create() else {
            fatalError("facet_seam_create returned null (seam allocation failed)")
        }
        let measureStatus = facet_seam_set_measure_callback(handle, facetMeasureText)
        precondition(measureStatus == 0, "facet_seam_set_measure_callback rejected the production callback (status \(measureStatus))")
        let shapeStatus = facet_seam_set_shape_callback(handle, makeFacetShapeText(atlas: renderer.atlas))
        precondition(shapeStatus == 0, "facet_seam_set_shape_callback rejected the production callback (status \(shapeStatus))")

        let rootId = facet_seam_build_measure_tree(handle)
        precondition(rootId != UInt32.max, "facet_seam_build_measure_tree failed to build the measure scene")

        let base = renderer.sharedInstanceBufferBaseAddress.assumingMemoryBound(to: FacetInstance.self)
        _ = facet_seam_set_base_pointer(handle, base, UInt32(renderer.sharedInstanceCapacity))
        let count = facet_seam_give_instances(handle, rootId, Float(ReferenceZigTree.width), Float(ReferenceZigTree.height))
        precondition(count >= 0, "the measure scene produce overflowed or failed (status \(count))")
        return DrivenMeasureScene(handle: handle, rootId: rootId, instanceCount: Int(count))
    }

    // The glyph instances of the produced scene: the produced array is the background
    // root, the label container, then one glyph instance per shaped glyph (forward
    // paint order), so the glyphs are the suffix after the two SDF instances.
    private static func readGlyphInstances(renderer: Renderer, scene: DrivenMeasureScene) -> [Instance] {
        let base = renderer.sharedInstanceBufferBaseAddress.assumingMemoryBound(to: Instance.self)
        var glyphInstances: [Instance] = []
        var index = sdfInstanceCount
        while index < scene.instanceCount {
            glyphInstances.append(base[index])
            index += 1
        }
        return glyphInstances
    }

    // The shaped line's total advance, the Ф6 formula: an independent Swift
    // Shaper.shape of the same string/font, (last.origin.x − lineOrigin.x) +
    // last.advance. Anchored at origin 0 so origin.x is the per-glyph pen offset.
    private static func independentShapedAdvance(font: CTFont) -> Float {
        let shaped = Shaper.shape(string: ReferenceZigTree.measureString, font: font, origin: (0, 0))
        precondition(!shaped.isEmpty, "measure↔shape: the fixture string must shape to at least one glyph")
        let last = shaped[shaped.count - 1]
        return (last.origin.x - 0) + last.advance
    }

    private static func referenceFont() -> CTFont {
        CTFontCreateWithName(
            ReferenceZigTree.measureFontName as CFString,
            ReferenceZigTree.measureFontSize,
            nil
        )
    }

    // The two leading SDF instances (the background root and the label container)
    // before the glyph suffix in the produced array.
    private static let sdfInstanceCount = 2
    private static let glyphInstanceType: UInt32 = 1

    // Scans a glyph instance's drawable-pixel cell for the first pixel that differs
    // from the clear color by more than AA noise — a rendered stroke (the Ф6
    // ShaperSnapshotTests probe, inlined here to keep the e2e self-contained).
    private static let strokeChannelDelta = 10

    private static func findStrokePixel(
        _ frame: CapturedFrame,
        inCellOf instance: Instance
    ) -> (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8)? {
        let clear = clearColorBytes()
        let minX = max(0, Int((instance.positionX - instance.width / 2).rounded(.down)))
        let maxX = min(frame.width - 1, Int((instance.positionX + instance.width / 2).rounded(.up)))
        let minY = max(0, Int((instance.positionY - instance.height / 2).rounded(.down)))
        let maxY = min(frame.height - 1, Int((instance.positionY + instance.height / 2).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return nil }
        for y in minY...maxY {
            for x in minX...maxX {
                let candidate = SnapshotComparator.pixel(frame, x, y)
                if channelDistance(candidate, clear) > strokeChannelDelta {
                    return candidate
                }
            }
        }
        return nil
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

    private static func clearColorBytes() -> (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8) {
        let clear = Renderer.clearColor
        return (
            blue: UInt8((Double(clear.blue) * 255.0).rounded()),
            green: UInt8((Double(clear.green) * 255.0).rounded()),
            red: UInt8((Double(clear.red) * 255.0).rounded()),
            alpha: UInt8((Double(clear.alpha) * 255.0).rounded())
        )
    }
}
