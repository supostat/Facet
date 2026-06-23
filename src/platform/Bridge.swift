import Foundation

// The Swift side of the Р13 lower seam. Owns the opaque Zig seam handle and drives
// the per-frame has-changed -> produce loop, handing the renderer's
// StorageModeShared MTLBuffer base to Zig so the seam writes instances straight
// into GPU-visible memory (zero-copy via unified memory). The base pointer is
// NEVER retained past a produce call — it is frame-scoped, re-handed on every grow.
//
// Bridge is held by Window; Window owns the frame loop and the renderer, Bridge
// owns the seam handle and the node->buffer hand-off. The handle is an opaque
// *anyopaque (no module-global singleton), so a second seam (the КТ-2 harness, the
// e2e test) is fully independent.
final class Bridge {
    private let renderer: Renderer
    private let handle: UnsafeMutableRawPointer
    let rootId: UInt32
    private(set) var lastInstanceCount: Int = 0

    init(renderer: Renderer) {
        // The three types over the same 104 bytes must agree (Р13). A drift here is
        // a memory-corruption boundary, so it traps before any produce.
        precondition(
            MemoryLayout<Instance>.stride == 104,
            "Instance stride must be 104 bytes (Р13 contract), got \(MemoryLayout<Instance>.stride)"
        )
        precondition(
            MemoryLayout<FacetInstance>.stride == MemoryLayout<Instance>.stride,
            "FacetInstance and Instance must share the same stride (Р13 contract)"
        )

        self.renderer = renderer
        guard let handle = facet_seam_create() else {
            fatalError("facet_seam_create returned null (seam allocation failed)")
        }
        self.handle = handle

        let rootId = facet_seam_build_reference_tree(handle)
        precondition(rootId != UInt32.max, "facet_seam_build_reference_tree failed to build the tree")
        self.rootId = rootId

        // Install the Ф14 measure callback AFTER the tree is built and BEFORE the
        // first produce (the install-order invariant): build_*_tree does not
        // measure, so the callback need not exist yet, but the first produce drives
        // the measure pass and a measure with a null seam slot is a checked panic.
        // The Phase-13 reference tree has no text node so it never crosses; a measure
        // scene built later through the same seam finds the callback already live.
        let measureStatus = facet_seam_set_measure_callback(handle, facetMeasureText)
        precondition(measureStatus == 0, "facet_seam_set_measure_callback rejected the callback (status \(measureStatus))")

        // Install the Phase-14b shape callback under the same install-order
        // discipline. It needs the live Atlas, which the @convention(c) closure
        // cannot capture (the C contract has no user-data pointer), so
        // makeFacetShapeText sets a file-private slot in ShapeCallback.swift before
        // returning the closure. The Phase-13 reference tree has no text node, so the
        // callback installs dormant for it; a text scene built through the same seam
        // finds it already live.
        let shapeStatus = facet_seam_set_shape_callback(handle, makeFacetShapeText(atlas: renderer.atlas))
        precondition(shapeStatus == 0, "facet_seam_set_shape_callback rejected the callback (status \(shapeStatus))")

        rehandBase()
    }

    deinit {
        facet_seam_destroy(handle)
    }

    func hasChanged() -> Bool {
        facet_seam_has_changed(handle)
    }

    func mutate() {
        facet_seam_mutate_reference(handle)
    }

    var lastRecomputedNodeCount: Int {
        Int(facet_seam_last_recomputed(handle))
    }

    // Produces the instance array for the current frame straight into the shared
    // buffer and returns the instance count to draw. On an overflow the seam reports
    // the required count; the buffer is grown 2x, the new base re-handed, and the
    // produce retried once (the grown buffer is guaranteed to fit). The base pointer
    // is handed in and forgotten within the call — never stored.
    @discardableResult
    func produceInstances(drawableWidth: Float, drawableHeight: Float) -> Int {
        let result = facet_seam_give_instances(handle, rootId, drawableWidth, drawableHeight)
        if result < 0 {
            let required = Int(-result - 1)
            renderer.growSharedInstanceBuffer(toFit: required)
            rehandBase()
            let retried = facet_seam_give_instances(handle, rootId, drawableWidth, drawableHeight)
            precondition(retried >= 0, "give-instances still overflowed after growing to fit \(required)")
            lastInstanceCount = Int(retried)
            return lastInstanceCount
        }
        lastInstanceCount = Int(result)
        return lastInstanceCount
    }

    // Hands the renderer's current shared-buffer base + capacity to the seam. Called
    // at init and after every grow (the base changes on a grow). A rejected status
    // is a hard boundary error — a null base or zero capacity is a construction bug.
    private func rehandBase() {
        let base = renderer.sharedInstanceBufferBaseAddress.assumingMemoryBound(to: FacetInstance.self)
        let status = facet_seam_set_base_pointer(handle, base, UInt32(renderer.sharedInstanceCapacity))
        precondition(status == 0, "facet_seam_set_base_pointer rejected the base/capacity (status \(status))")
    }
}
