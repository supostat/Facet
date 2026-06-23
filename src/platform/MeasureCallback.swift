import CoreGraphics
import CoreText
import Foundation

// The Ф14 measure-seam callback the Zig core invokes UPWARD through the lower
// C-ABI seam (Р10): given a MeasureRequest it builds a String from the zero-copy
// byte borrow, resolves the fixed-family CTFont at the requested point size,
// measures one line with real Core Text (Shaper.measure), and writes the metrics
// into the result. Bridge.init installs it via facet_seam_set_measure_callback
// before the first produce.
//
// It lives in its OWN file — NOT in Shaper.swift — because it references the
// FacetMeasureRequest/FacetMeasureResult types from the C bridging header, which
// only the seam consumers (the app, the КТ-2 harness, the seam e2e tests) import.
// The pure-Swift shaper/text snapshot tests compile Shaper.swift WITHOUT the
// header, so the header-dependent closure cannot live there. Shaper keeps the
// header-free `Shaper.measure`; this file is added to the seam source arrays only.
//
// A top-level `let` of a `@convention(c)` closure — NOT a `@convention(c) func`,
// which does not compile. The Optional parameters are the C-ABI nullable pointer
// shape; they are guaranteed non-null by the Zig caller (it always packs a request
// and a result), so a null is a construction bug — the guard traps (fails CLOSED,
// symmetric with the Zig adapter's `measure_fn_slot.* orelse unreachable`) rather
// than masking it with a silent return. The `bytes` pointer is read ONLY within this
// call (a String is decoded from the UTF-8 buffer) and never retained, honoring the
// seam's zero-copy lifetime discipline.
let facetMeasureText: @convention(c) (UnsafePointer<FacetMeasureRequest>?, UnsafeMutablePointer<FacetMeasureResult>?) -> Void = { requestPointer, resultPointer in
    guard let requestPointer, let resultPointer else {
        preconditionFailure("facetMeasureText invoked with a null request/result pointer — the Zig measure seam always passes non-null")
    }
    let request = requestPointer.pointee
    let buffer = UnsafeBufferPointer(start: request.bytes, count: request.length)
    let string = String(decoding: buffer, as: UTF8.self)
    let font = CTFontCreateWithName(Shaper.measureFontName as CFString, CGFloat(request.font_size), nil)
    let measured = Shaper.measure(string: string, font: font)
    resultPointer.pointee = FacetMeasureResult(main: Float(measured.main), cross: Float(measured.cross))
}
