import CoreText
import Foundation
import Metal

// Cache key for a rasterized glyph: a glyph is uniquely identified by its font
// family, point size, and CGGlyph index. The font name is the stable PostScript
// name, used both for cache identity and as the deterministic machine-dump field.
struct GlyphKey: Hashable {
    let fontName: String
    let pointSize: CGFloat
    let glyph: CGGlyph
}

// Where a glyph lives in the atlas plus its positioning metrics. `pixelRect` is
// the placement in top-left atlas pixel space; `normalizedRect` is the same rect
// in [0, 1] texture coordinates for sampling; `bearing`/`advance` carry the
// typographic metrics from the rasterizer. `insertionIndex` is the monotonic
// order the glyph was first inserted, giving the inspector a stable dump order
// and grow() a stable re-pack order.
struct GlyphPlacement {
    let pixelRect: PackedRectangle
    let normalizedRect: (minU: Float, minV: Float, maxU: Float, maxV: Float)
    let bearing: SIMD2<Float>
    let advance: Float
    let insertionIndex: Int
}

// The lazy multi-font glyph atlas: a single .r8Unorm MTLTexture fed by a Core
// Text rasterizer and a shelf bin-packer, cached by (font, point size, glyph).
// lookup() is the single contract: a hit returns the cached placement with no
// Core Text work; a miss rasterizes, packs, uploads, caches, and returns. When
// the packer overflows, the atlas grows to a larger texture and re-rasterizes
// every live entry from its RETAINED CTFont in insertion order — no PostScript
// round-trip. The texture is .shaderRead .shared so the bench/snapshot path can
// read it back and a future glyph shader can sample it.
final class Atlas {
    static let initialAtlasSize = 512
    static let atlasGrowthFactor = 2
    static let maximumAtlasSize = 8192

    private let device: MTLDevice
    private let rasterizer: GlyphRasterizer
    private let packer: ShelfPacker

    private(set) var texture: MTLTexture
    private(set) var size: Int

    // Retained per live entry so grow() can re-rasterize without recreating the
    // CTFont. Parallel to `placements` by key; both are rebuilt on grow().
    private var placements: [GlyphKey: GlyphPlacement] = [:]
    private var retainedFonts: [GlyphKey: CTFont] = [:]
    private var nextInsertionIndex = 0

    convenience init(device: MTLDevice) {
        self.init(device: device, initialSize: Self.initialAtlasSize)
    }

    // Test-only entry point: a small initial size makes deterministic overflow
    // cheap to provoke without rasterizing hundreds of glyphs.
    init(device: MTLDevice, initialSize: Int) {
        precondition(initialSize > 0, "Atlas initial size must be positive, got \(initialSize)")
        self.device = device
        self.rasterizer = GlyphRasterizer()
        self.packer = ShelfPacker(size: initialSize)
        self.size = initialSize
        self.texture = Self.makeAtlasTexture(device: device, size: initialSize)
    }

    var rasterizationCount: Int { rasterizer.rasterizationCount }
    var shelfCount: Int { packer.shelfCount }

    // The single lookup contract. A cache hit returns the placement and touches
    // no Core Text; a miss rasterizes, packs, uploads, and caches before
    // returning. The CTFont is retained on first insert for later re-packing.
    func lookup(font: CTFont, glyph: CGGlyph) -> GlyphPlacement {
        let key = GlyphKey(
            fontName: postScriptName(of: font),
            pointSize: CTFontGetSize(font),
            glyph: glyph
        )
        if let cached = placements[key] {
            return cached
        }
        retainedFonts[key] = font
        return insert(key: key, font: font, glyph: glyph)
    }

    private func insert(key: GlyphKey, font: CTFont, glyph: CGGlyph) -> GlyphPlacement {
        let rasterized = rasterizer.rasterize(glyph: glyph, in: font)
        guard let rectangle = packer.place(maskWidth: rasterized.width, maskHeight: rasterized.height) else {
            grow()
            return insertAfterGrow(key: key, font: font, glyph: glyph)
        }
        return commit(key: key, rasterized: rasterized, rectangle: rectangle)
    }

    // After a grow() the packer is empty and far larger, so a single re-place
    // must succeed; a failure here means the glyph exceeds the maximum atlas and
    // is a fail-fast construction error, not a retry loop.
    private func insertAfterGrow(key: GlyphKey, font: CTFont, glyph: CGGlyph) -> GlyphPlacement {
        let rasterized = rasterizer.rasterize(glyph: glyph, in: font)
        guard let rectangle = packer.place(maskWidth: rasterized.width, maskHeight: rasterized.height) else {
            fatalError("Atlas: glyph \(rasterized.width)x\(rasterized.height) does not fit a \(size)x\(size) atlas")
        }
        return commit(key: key, rasterized: rasterized, rectangle: rectangle)
    }

    private func commit(
        key: GlyphKey,
        rasterized: RasterizedGlyph,
        rectangle: PackedRectangle
    ) -> GlyphPlacement {
        upload(mask: rasterized.alphaMask, into: rectangle)
        let placement = GlyphPlacement(
            pixelRect: rectangle,
            normalizedRect: normalizedRect(of: rectangle),
            bearing: rasterized.bearing,
            advance: rasterized.advance,
            insertionIndex: nextInsertionIndex
        )
        nextInsertionIndex += 1
        placements[key] = placement
        return placement
    }

    // Doubles the atlas, recreates the texture, resets the packer, and
    // re-rasterizes + re-places every live entry from its retained CTFont in
    // insertion order so the new layout is deterministic. insertionIndex is
    // preserved so the dump order is stable across a grow.
    private func grow() {
        let newSize = size * Self.atlasGrowthFactor
        precondition(
            newSize <= Self.maximumAtlasSize,
            "Atlas exceeded the maximum size of \(Self.maximumAtlasSize) (tried \(newSize))"
        )
        size = newSize
        texture = Self.makeAtlasTexture(device: device, size: newSize)
        packer.reset(size: newSize)

        let live = placements.sorted { $0.value.insertionIndex < $1.value.insertionIndex }
        placements.removeAll(keepingCapacity: true)
        for (key, previous) in live {
            guard let font = retainedFonts[key] else {
                fatalError("Atlas: missing retained font for \(key.fontName) during grow")
            }
            let rasterized = rasterizer.rasterize(glyph: key.glyph, in: font)
            guard let rectangle = packer.place(maskWidth: rasterized.width, maskHeight: rasterized.height) else {
                fatalError("Atlas: glyph \(rasterized.width)x\(rasterized.height) does not fit a \(newSize)x\(newSize) atlas after grow")
            }
            upload(mask: rasterized.alphaMask, into: rectangle)
            placements[key] = GlyphPlacement(
                pixelRect: rectangle,
                normalizedRect: normalizedRect(of: rectangle),
                bearing: rasterized.bearing,
                advance: rasterized.advance,
                insertionIndex: previous.insertionIndex
            )
        }
    }

    // R8 .shared upload: one byte per pixel means bytesPerRow == rect.width with
    // no 256-byte alignment (that constraint is blit/buffer-backed only).
    private func upload(mask: [UInt8], into rectangle: PackedRectangle) {
        let region = MTLRegionMake2D(rectangle.x, rectangle.y, rectangle.width, rectangle.height)
        mask.withUnsafeBytes { source in
            texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: source.baseAddress!,
                bytesPerRow: rectangle.width
            )
        }
    }

    func snapshot() -> AtlasSnapshot {
        let entries = placements
            .sorted { $0.value.insertionIndex < $1.value.insertionIndex }
            .map { key, placement in
                AtlasSnapshot.Entry(
                    fontName: key.fontName,
                    pointSize: key.pointSize,
                    glyph: key.glyph,
                    placement: placement
                )
            }
        return AtlasSnapshot(size: size, shelfCount: packer.shelfCount, entries: entries)
    }

    private func normalizedRect(
        of rectangle: PackedRectangle
    ) -> (minU: Float, minV: Float, maxU: Float, maxV: Float) {
        let dimension = Float(size)
        return (
            minU: Float(rectangle.x) / dimension,
            minV: Float(rectangle.y) / dimension,
            maxU: Float(rectangle.x + rectangle.width) / dimension,
            maxV: Float(rectangle.y + rectangle.height) / dimension
        )
    }

    private func postScriptName(of font: CTFont) -> String {
        CTFontCopyPostScriptName(font) as String
    }

    private static func makeAtlasTexture(device: MTLDevice, size: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("Atlas: could not create an \(size)x\(size) r8Unorm texture")
        }
        return texture
    }
}
