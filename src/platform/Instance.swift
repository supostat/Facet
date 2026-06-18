import Foundation

// The kind of primitive an Instance describes. The raw value is the contract
// shared verbatim with the MSL `enum`/switch in sdf.metal. Stored as UInt32 to
// match the MSL `uint` field with no padding. `glyph` selects the atlas-sampling
// branch in sdf_vertex/sdf_fragment; the SDF and glyph kinds draw together in one
// instanced pass, distinguished only by this discriminant.
enum InstanceType: UInt32 {
    case sdfRoundedRect = 0
    case glyph = 1
}

// One GPU instance: a flat, behavior-free value with a fixed C-compatible field
// order. The field order IS the Р13 contract — the MSL `struct Instance` in
// sdf.metal mirrors it field-for-field, and a future Zig `extern struct` will
// mirror it again. The layout is 25 Float fields with one UInt32 (`type`) wedged
// at field 10, giving a 104-byte stride with no trailing padding, so the array
// uploads as a packed buffer.
//
// The first ten fields (offsets 0..36) are the Phase 2 body: positionX/Y,
// width/height, colorR/G/B/A, cornerRadius, type. Those offsets are frozen —
// shadow, border, and the atlas rect were APPENDED after `type` so earlier
// goldens stay byte-identical. Offsets 40..84 are the Phase 3 shadow + border:
// shadowOffsetX/Y, shadowBlurRadius, shadowColorR/G/B/A, borderThickness,
// borderColorR/G/B/A. The trailing four floats (offsets 88..100) are the Phase 5
// glyph atlas sub-rectangle: atlasMinU/atlasMinV/atlasMaxU/atlasMaxV. All
// appended defaults are inert — shadowColorA 0, borderThickness 0, blur 0,
// offset 0, atlas rect (0,0,0,0) — so an SDF instance composites exactly as
// before (no shadow contribution, border band collapses to nothing, quad is not
// inflated, glyph branch never taken).
//
// Geometry is expressed in drawable pixels with a top-left origin: positionX/Y
// is the rectangle center, width/height its full extent. Color is
// straight-alpha RGBA in [0, 1]; the shader premultiplies. cornerRadius and
// borderThickness are in pixels and are clamped to half the shorter side by the
// shader. shadowOffset shifts the shadow silhouette in pixels; shadowBlurRadius
// is the soft falloff half-width; shadowColor is straight-alpha RGBA. For a
// glyph instance (type == .glyph) the atlasMin/Max U/V name the glyph's
// sub-rectangle in [0, 1] atlas texture coordinates and `color` tints the
// sampled R8 coverage.
struct Instance {
    var positionX: Float
    var positionY: Float
    var width: Float
    var height: Float
    var colorR: Float
    var colorG: Float
    var colorB: Float
    var colorA: Float
    var cornerRadius: Float
    var type: UInt32
    var shadowOffsetX: Float
    var shadowOffsetY: Float
    var shadowBlurRadius: Float
    var shadowColorR: Float
    var shadowColorG: Float
    var shadowColorB: Float
    var shadowColorA: Float
    var borderThickness: Float
    var borderColorR: Float
    var borderColorG: Float
    var borderColorB: Float
    var borderColorA: Float
    var atlasMinU: Float
    var atlasMinV: Float
    var atlasMaxU: Float
    var atlasMaxV: Float

    init(
        center: (x: Float, y: Float),
        size: (width: Float, height: Float),
        color: (r: Float, g: Float, b: Float, a: Float),
        cornerRadius: Float,
        type: InstanceType = .sdfRoundedRect,
        shadowOffset: (x: Float, y: Float) = (0, 0),
        shadowBlurRadius: Float = 0,
        shadowColor: (r: Float, g: Float, b: Float, a: Float) = (0, 0, 0, 0),
        borderThickness: Float = 0,
        borderColor: (r: Float, g: Float, b: Float, a: Float) = (0, 0, 0, 0),
        atlasRect: (minU: Float, minV: Float, maxU: Float, maxV: Float) = (0, 0, 0, 0)
    ) {
        positionX = center.x
        positionY = center.y
        width = size.width
        height = size.height
        colorR = color.r
        colorG = color.g
        colorB = color.b
        colorA = color.a
        self.cornerRadius = cornerRadius
        self.type = type.rawValue
        shadowOffsetX = shadowOffset.x
        shadowOffsetY = shadowOffset.y
        self.shadowBlurRadius = shadowBlurRadius
        shadowColorR = shadowColor.r
        shadowColorG = shadowColor.g
        shadowColorB = shadowColor.b
        shadowColorA = shadowColor.a
        self.borderThickness = borderThickness
        borderColorR = borderColor.r
        borderColorG = borderColor.g
        borderColorB = borderColor.b
        borderColorA = borderColor.a
        atlasMinU = atlasRect.minU
        atlasMinV = atlasRect.minV
        atlasMaxU = atlasRect.maxU
        atlasMaxV = atlasRect.maxV
    }

    // Hardcoded scene for the windowed app and the snapshot golden (§0a:
    // the renderer never builds a scene; this external supplier does). Authored
    // against a 1024x640 drawable. Deliberately ASYMMETRIC across the horizontal
    // midline — the top row and bottom row differ in count, color, position, and
    // radius — so a vertical (Y) flip accidentally baked into a golden is
    // immediately visible to a human eye-check.
    static let referenceScene: [Instance] = [
        // Top band: one wide, gently rounded magenta bar near the top edge.
        Instance(
            center: (x: 360, y: 150),
            size: (width: 560, height: 120),
            color: (r: 0.92, g: 0.20, b: 0.55, a: 1.0),
            cornerRadius: 28
        ),
        // Top-right: a small, sharp-ish teal square offset to one side.
        Instance(
            center: (x: 820, y: 110),
            size: (width: 150, height: 150),
            color: (r: 0.10, g: 0.78, b: 0.74, a: 1.0),
            cornerRadius: 12
        ),
        // Center-left: a translucent amber capsule to exercise blending.
        Instance(
            center: (x: 300, y: 360),
            size: (width: 360, height: 140),
            color: (r: 1.0, g: 0.72, b: 0.16, a: 0.6),
            cornerRadius: 70
        ),
        // Bottom band: three differently sized indigo tiles, none mirroring the
        // top — confirms top != bottom under any flip.
        Instance(
            center: (x: 240, y: 520),
            size: (width: 220, height: 160),
            color: (r: 0.36, g: 0.40, b: 0.95, a: 1.0),
            cornerRadius: 40
        ),
        Instance(
            center: (x: 540, y: 540),
            size: (width: 160, height: 120),
            color: (r: 0.30, g: 0.55, b: 0.90, a: 1.0),
            cornerRadius: 24
        ),
        Instance(
            center: (x: 800, y: 500),
            size: (width: 300, height: 200),
            color: (r: 0.50, g: 0.30, b: 0.85, a: 1.0),
            cornerRadius: 16
        ),
    ]

    // Single fully-rounded shape (radius == half the shorter side) becomes a
    // capsule/circle — the upper boundary of the radius clamp.
    static let radiusHalfSideScene: [Instance] = [
        Instance(
            center: (x: 512, y: 320),
            size: (width: 400, height: 240),
            color: (r: 0.95, g: 0.85, b: 0.30, a: 1.0),
            cornerRadius: 120
        ),
    ]

    // Single zero-radius shape collapses the SDF to a sharp axis-aligned box —
    // the lower boundary of the radius clamp.
    static let radiusZeroScene: [Instance] = [
        Instance(
            center: (x: 512, y: 320),
            size: (width: 420, height: 260),
            color: (r: 0.30, g: 0.85, b: 0.45, a: 1.0),
            cornerRadius: 0
        ),
    ]

    // Single opaque light card casting a soft, offset drop shadow — exercises the
    // shadow underlay alone (no border). The offset+blur extent reaches well
    // beyond the body so the soft falloff and the occlusion-by-opaque-fill are
    // both visible. Body halfSize is (180, 110).
    static let shadowScene: [Instance] = [
        Instance(
            center: (x: 512, y: 320),
            size: (width: 360, height: 220),
            color: (r: 0.85, g: 0.85, b: 0.88, a: 1.0),
            cornerRadius: 32,
            shadowOffset: (x: 24, y: 24),
            shadowBlurRadius: 28,
            shadowColor: (r: 0.0, g: 0.0, b: 0.0, a: 0.6)
        ),
    ]

    // Single blue card with a thick opaque white border — exercises the border
    // band alone (no shadow). The 16px band, blue interior, and clear exterior
    // give three distinct analytic spot regions.
    static let borderScene: [Instance] = [
        Instance(
            center: (x: 512, y: 320),
            size: (width: 360, height: 220),
            color: (r: 0.20, g: 0.55, b: 0.95, a: 1.0),
            cornerRadius: 40,
            borderThickness: 16,
            borderColor: (r: 1.0, g: 1.0, b: 1.0, a: 1.0)
        ),
    ]

    // Shadow AND border on one blue card — exercises the full composite. The
    // opaque body occludes the shadow within the border band, so a band pixel
    // resolves to the border color, proving the shadow→fill→border order.
    static let combinedScene: [Instance] = [
        Instance(
            center: (x: 512, y: 320),
            size: (width: 360, height: 220),
            color: (r: 0.20, g: 0.55, b: 0.95, a: 1.0),
            cornerRadius: 40,
            shadowOffset: (x: 24, y: 24),
            shadowBlurRadius: 28,
            shadowColor: (r: 0.0, g: 0.0, b: 0.0, a: 0.6),
            borderThickness: 16,
            borderColor: (r: 1.0, g: 1.0, b: 1.0, a: 1.0)
        ),
    ]
}
