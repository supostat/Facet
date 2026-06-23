import CoreGraphics
import CoreText
import Foundation

// The Phase-14b shape-seam callback the Zig core invokes UPWARD through the lower
// C-ABI seam (Р10): given a ShapeRequest it builds a String from the zero-copy byte
// borrow, resolves the fixed-family CTFont at the requested point size, derives the
// baseline from the node's laid-out top-left, shapes the line with real Core Text +
// the Atlas (Shaper.placedGlyphs), and writes the per-glyph geometry into the
// destination buffer (or returns the overflow encoding so Zig grows its scratch and
// re-calls). Bridge.init installs it via facet_seam_set_shape_callback before the
// first produce. It is the VARIABLE-LENGTH mirror of MeasureCallback.swift.
//
// It lives in its OWN file — NOT in Shaper.swift — because it references the
// FacetShapeRequest/FacetPlacedGlyph types from the C bridging header, which only
// the seam consumers (the app, the КТ-2 harness, the seam e2e tests) import. The
// pure-Swift shaper/text snapshot tests compile Shaper.swift WITHOUT the header, so
// the header-dependent closure cannot live there. Shaper keeps the header-free
// `Shaper.placedGlyphs`; this file is added to the seam source arrays only.

// The live Atlas the shape callback reads. This DIVERGES from MeasureCallback's
// stateless `let facetMeasureText`: the C FacetShapeCallback contract has no
// user-data pointer (it mirrors FacetMeasureCallback), so the @convention(c) closure
// cannot capture the live Atlas and must read it from this file-private slot.
//
// nonisolated(unsafe): the slot is written ONCE by makeFacetShapeText during
// Bridge.init — before the first produce — and only ever read thereafter on the same
// thread the seam is driven from (the install-before-first-produce single-threaded
// discipline). The annotation documents that deliberate discipline and future-proofs
// a -swift-version 6 flip; under the project's default Swift-5 mode a plain global
// would also compile.
nonisolated(unsafe) private var facetShapeAtlas: Atlas?

// Installs the live Atlas into the file-private slot and returns the @convention(c)
// shape closure for facet_seam_set_shape_callback. Called once during Bridge.init,
// before the first produce — the install-order invariant the seam relies on.
func makeFacetShapeText(atlas: Atlas) -> FacetShapeCallback {
    facetShapeAtlas = atlas
    return facetShapeText
}

// A top-level `let` of a `@convention(c)` closure — NOT a `@convention(c) func`,
// which does not compile. The Optional parameters are the C-ABI nullable pointer
// shape; they are guaranteed non-null by the Zig caller (it always packs a request
// and hands a destination), and the atlas is guaranteed installed by the
// install-order invariant, so a null is a construction bug — the guard traps (fails
// CLOSED, symmetric with the Zig adapter's `shape_fn_slot.* orelse unreachable`)
// rather than masking it with a silent return. The `bytes` pointer is read ONLY
// within this call (a String is decoded from the UTF-8 buffer) and never retained.
let facetShapeText: @convention(c) (UnsafePointer<FacetShapeRequest>?, UnsafeMutablePointer<FacetPlacedGlyph>?, CLong) -> CLong = { requestPointer, destinationPointer, capacity in
    guard let requestPointer, let destinationPointer else {
        preconditionFailure("facetShapeText invoked with a null request/destination pointer — the Zig shape seam always passes non-null")
    }
    guard let atlas = facetShapeAtlas else {
        preconditionFailure("facetShapeText invoked before makeFacetShapeText installed the atlas — the install-order invariant was violated")
    }

    let request = requestPointer.pointee
    let buffer = UnsafeBufferPointer(start: request.bytes, count: request.length)
    let string = String(decoding: buffer, as: UTF8.self)
    let font = CTFontCreateWithName(Shaper.measureFontName as CFString, CGFloat(request.font_size), nil)
    // The node's layout.{x,y} is the box top-left; a glyph cell center sits on the
    // baseline, so the line origin's Y is the box top plus the resolved ascent.
    let baselineY = request.origin_y + Float(CTFontGetAscent(font))
    let placed = Shaper.placedGlyphs(
        string: string,
        font: font,
        origin: (x: request.origin_x, y: baselineY),
        atlas: atlas
    )

    let count = placed.count
    if count > capacity {
        // Overflow: write nothing past the seam-owned capacity and signal the
        // required count so Zig grows its scratch and re-calls.
        return -(CLong(count) + 1)
    }
    for index in 0..<count {
        let glyph = placed[index]
        destinationPointer[index] = FacetPlacedGlyph(
            center_x: glyph.centerX,
            center_y: glyph.centerY,
            width: glyph.width,
            height: glyph.height,
            atlas_min_u: glyph.atlasMinU,
            atlas_min_v: glyph.atlasMinV,
            atlas_max_u: glyph.atlasMaxU,
            atlas_max_v: glyph.atlasMaxV
        )
    }
    return CLong(count)
}
