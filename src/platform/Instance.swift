import Foundation

// The kind of primitive an Instance describes. The raw value is the contract
// shared verbatim with the MSL `enum`/switch in sdf.metal; Phase 2 ships a
// single case. Stored as UInt32 to match the MSL `uint` field with no padding.
enum InstanceType: UInt32 {
    case sdfRoundedRect = 0
}

// One GPU instance: a flat, behavior-free value with a fixed C-compatible field
// order. The field order IS the Р13 contract — the MSL `struct Instance` in
// sdf.metal mirrors it field-for-field, and a future Zig `extern struct` will
// mirror it again. Nine Float fields followed by one UInt32 give a 40-byte
// stride with no trailing padding, so the array uploads as a packed buffer.
//
// Geometry is expressed in drawable pixels with a top-left origin: positionX/Y
// is the rectangle center, width/height its full extent. Color is
// straight-alpha RGBA in [0, 1]; the shader premultiplies. cornerRadius is in
// pixels and is clamped to half the shorter side by the shader.
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

    init(
        center: (x: Float, y: Float),
        size: (width: Float, height: Float),
        color: (r: Float, g: Float, b: Float, a: Float),
        cornerRadius: Float,
        type: InstanceType = .sdfRoundedRect
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
}
