import AppKit
import Foundation
import Metal
import QuartzCore

// One glyph quad for the bench atlas viewer — the CPU mirror of the MSL
// `GlyphQuad` in glyph.metal, field-for-field: a destination rectangle in
// drawable pixels (top-left origin), the atlas sub-rectangle in normalized
// texture coordinates, and a straight-alpha RGBA tint. Bench-only; not the
// production Instance contract.
struct GlyphQuad {
    var destinationX: Float
    var destinationY: Float
    var destinationWidth: Float
    var destinationHeight: Float
    var atlasMinU: Float
    var atlasMinV: Float
    var atlasMaxU: Float
    var atlasMaxV: Float
    var tintR: Float
    var tintG: Float
    var tintB: Float
    var tintA: Float
}

// The bench-side live atlas viewer window. It builds the fixed ReferenceAtlas,
// then lays its glyphs out as a wrapped row of tinted quads sampled from the R8
// atlas texture through the glyph_vertex/glyph_fragment shader folded into
// sdf.metallib. This is the only site that exercises the glyph pipeline this
// phase — the production Renderer does not build one. Confined to the harness.
final class AtlasViewerWindow: NSObject, NSWindowDelegate {
    private static let contentSize = NSSize(width: 1024, height: 640)
    private static let clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
    private static let glyphTint = SIMD4<Float>(0.95, 0.95, 0.98, 1.0)

    private let window: NSWindow
    private let metalLayer: CAMetalLayer
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let glyphPipelineState: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let atlas: Atlas
    private let quadBuffer: MTLBuffer
    private let quadCount: Int
    private let frameLoop: FrameLoop

    init(metallibPath: String) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is unavailable: MTLCreateSystemDefaultDevice returned nil")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("Failed to create a Metal command queue for the atlas viewer")
        }
        self.device = device
        self.commandQueue = commandQueue

        let library = Self.loadLibrary(device: device, path: metallibPath)
        self.glyphPipelineState = Self.makeGlyphPipelineState(device: device, library: library)
        self.sampler = Self.makeSampler(device: device)

        let atlas = ReferenceAtlas.build(device: device)
        self.atlas = atlas
        let quads = Self.layoutGlyphs(atlas: atlas)
        self.quadCount = quads.count
        guard let buffer = device.makeBuffer(
            length: max(1, quads.count) * MemoryLayout<GlyphQuad>.stride,
            options: .storageModeShared
        ) else {
            fatalError("Failed to allocate the glyph quad buffer")
        }
        quads.withUnsafeBytes { source in
            buffer.contents().copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
        self.quadBuffer = buffer

        metalLayer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .resizable, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Facet — atlas viewer"

        let contentView = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
        contentView.wantsLayer = true
        contentView.layer = metalLayer
        window.contentView = contentView
        window.center()

        frameLoop = FrameLoop { [commandQueue, glyphPipelineState, sampler, metalLayer, atlas, buffer, quadCount = quads.count] in
            guard let drawable = metalLayer.nextDrawable() else { return }
            Self.encode(
                drawable: drawable,
                commandQueue: commandQueue,
                pipelineState: glyphPipelineState,
                sampler: sampler,
                atlas: atlas,
                quadBuffer: buffer,
                quadCount: quadCount
            )
        }

        super.init()
        window.delegate = self
        updateDrawableSize()
        print("atlas viewer: \(quads.count) glyph quads from a \(atlas.size)x\(atlas.size) atlas")
        print(AtlasInspector.prettyDump(atlas.snapshot()))
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        guard let contentView = window.contentView else {
            fatalError("AtlasViewerWindow has no content view to source the display link from")
        }
        frameLoop.start(view: contentView)
    }

    func windowDidResize(_ notification: Notification) { updateDrawableSize() }
    func windowDidChangeBackingProperties(_ notification: Notification) { updateDrawableSize() }
    func windowDidChangeScreen(_ notification: Notification) { updateDrawableSize() }
    func windowWillClose(_ notification: Notification) { frameLoop.stop() }

    private func updateDrawableSize() {
        guard let contentView = window.contentView else {
            fatalError("AtlasViewerWindow has no content view to size the drawable against")
        }
        let scale = window.backingScaleFactor
        metalLayer.contentsScale = scale
        let bounds = contentView.bounds
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    // Lays the atlas glyphs out as a left-to-right row that wraps, positioning
    // each quad by its bearing so the baseline is consistent — enough for a human
    // to read the rasterized shapes and confirm orientation.
    private static func layoutGlyphs(atlas: Atlas) -> [GlyphQuad] {
        let snapshot = atlas.snapshot()
        var quads: [GlyphQuad] = []
        let originX: Float = 40
        let lineHeight: Float = 80
        var penX = originX
        var baselineY: Float = 120
        let maxX = Float(Self.contentSize.width) - 40

        for entry in snapshot.entries {
            let rect = entry.placement.pixelRect
            let bearing = entry.placement.bearing
            if penX + Float(rect.width) > maxX {
                penX = originX
                baselineY += lineHeight
            }
            let destinationX = penX + bearing.x
            let destinationY = baselineY + bearing.y
            let normalized = entry.placement.normalizedRect
            quads.append(
                GlyphQuad(
                    destinationX: destinationX,
                    destinationY: destinationY,
                    destinationWidth: Float(rect.width),
                    destinationHeight: Float(rect.height),
                    atlasMinU: normalized.minU,
                    atlasMinV: normalized.minV,
                    atlasMaxU: normalized.maxU,
                    atlasMaxV: normalized.maxV,
                    tintR: glyphTint.x,
                    tintG: glyphTint.y,
                    tintB: glyphTint.z,
                    tintA: glyphTint.w
                )
            )
            penX += entry.placement.advance
        }
        return quads
    }

    private static func encode(
        drawable: CAMetalDrawable,
        commandQueue: MTLCommandQueue,
        pipelineState: MTLRenderPipelineState,
        sampler: MTLSamplerState,
        atlas: Atlas,
        quadBuffer: MTLBuffer,
        quadCount: Int
    ) {
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = drawable.texture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].clearColor = Self.clearColor
        renderPass.colorAttachments[0].storeAction = .store

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            fatalError("Failed to create a command buffer for the atlas viewer")
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            fatalError("Failed to create a render command encoder for the atlas viewer")
        }
        if quadCount > 0 {
            var drawableSize = SIMD2<Float>(Float(drawable.texture.width), Float(drawable.texture.height))
            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&drawableSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.setFragmentTexture(atlas.texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: quadCount)
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static func loadLibrary(device: MTLDevice, path: String) -> MTLLibrary {
        do {
            return try device.makeLibrary(URL: URL(fileURLWithPath: path))
        } catch {
            fatalError("Failed to load Metal library at \(path): \(error)")
        }
    }

    private static func makeGlyphPipelineState(device: MTLDevice, library: MTLLibrary) -> MTLRenderPipelineState {
        guard let vertexFunction = library.makeFunction(name: "glyph_vertex") else {
            fatalError("Metal library is missing the glyph_vertex function")
        }
        guard let fragmentFunction = library.makeFunction(name: "glyph_fragment") else {
            fatalError("Metal library is missing the glyph_fragment function")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction

        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("Failed to create the glyph render pipeline state: \(error)")
        }
    }

    private static func makeSampler(device: MTLDevice) -> MTLSamplerState {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
            fatalError("Failed to create the atlas sampler state")
        }
        return sampler
    }
}
