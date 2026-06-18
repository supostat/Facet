import Metal
import QuartzCore

struct CapturedFrame {
    let width: Int
    let height: Int
    let bgraPixels: [UInt8]
}

// Owns the Metal device, the single command queue, the SDF render pipeline, the
// loaded MTLLibrary, and a growable shared instance buffer. It is given a target
// and an external array of Instances per frame and draws them as ONE instanced
// draw call; it never builds a scene itself (Р2/КТ-1). An empty instance array
// produces zero draws and a byte-exact clear, preserving the Phase-1 path.
final class Renderer {
    // Channel values are exact multiples of 1/255, so the float->BGRA8 mapping
    // is lossless and the clear-frame test can assert exact bytes.
    static let clearColor = MTLClearColor(
        red: 12.0 / 255.0,
        green: 18.0 / 255.0,
        blue: 28.0 / 255.0,
        alpha: 1.0
    )

    private static let drawablePixelFormat: MTLPixelFormat = .bgra8Unorm
    private static let minimumInstanceCapacity = 16

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let sdfPipelineState: MTLRenderPipelineState

    // The lazy glyph atlas, created and owned with the renderer's device. Text is
    // drawn by the glyph branch of the single SDF pipeline (no separate glyph
    // pipeline object), so the atlas texture is bound on every draw alongside the
    // sampler below.
    let atlas: Atlas

    // The linear/clampToEdge sampler the glyph fragment branch reads the R8 atlas
    // through. Owned by the renderer because the atlas texture is bound on every
    // draw and the fragment shader declares a sampler at index 0 even when only
    // SDF instances are present (the bound sampler is simply never sampled then).
    private let atlasSampler: MTLSamplerState

    private var instanceBuffer: MTLBuffer
    private var instanceCapacity: Int

    // Machine-observable metrics: committedFrameCount increments at the single
    // commit() site; drawCallCount at the single drawPrimitives() site. The
    // snapshot/metric test asserts both advance by exactly 1 per drawn frame.
    private(set) var committedFrameCount: Int = 0
    private(set) var drawCallCount: Int = 0

    init(metallibPath: String) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is unavailable: MTLCreateSystemDefaultDevice returned nil")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("Failed to create a Metal command queue")
        }
        self.device = device
        self.commandQueue = commandQueue

        let library = Self.loadLibrary(device: device, path: metallibPath)
        self.sdfPipelineState = Self.makeSdfPipelineState(device: device, library: library)
        self.atlas = Atlas(device: device)
        self.atlasSampler = Self.makeSampler(device: device)

        self.instanceCapacity = Self.minimumInstanceCapacity
        guard let buffer = device.makeBuffer(
            length: Self.minimumInstanceCapacity * MemoryLayout<Instance>.stride,
            options: .storageModeShared
        ) else {
            fatalError("Failed to allocate the shared instance buffer")
        }
        self.instanceBuffer = buffer
    }

    private static func loadLibrary(device: MTLDevice, path: String) -> MTLLibrary {
        let url = URL(fileURLWithPath: path)
        do {
            return try device.makeLibrary(URL: url)
        } catch {
            fatalError("Failed to load Metal library at \(path): \(error)")
        }
    }

    // Linear min/mag, clampToEdge on both axes — matches the bench AtlasViewer's
    // sampler so the production glyph branch and the eye-check viewer sample the
    // atlas identically.
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

    private static func makeSdfPipelineState(
        device: MTLDevice,
        library: MTLLibrary
    ) -> MTLRenderPipelineState {
        guard let vertexFunction = library.makeFunction(name: "sdf_vertex") else {
            fatalError("Metal library is missing the sdf_vertex function")
        }
        guard let fragmentFunction = library.makeFunction(name: "sdf_fragment") else {
            fatalError("Metal library is missing the sdf_fragment function")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction

        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = drawablePixelFormat
        // Premultiplied-alpha "over" blending: the fragment shader already
        // multiplies rgb by alpha*coverage, so source uses .one.
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
            fatalError("Failed to create the SDF render pipeline state: \(error)")
        }
    }

    func drawSdfFrame(
        _ instances: [Instance],
        presentingTo drawable: CAMetalDrawable,
        targetTexture: MTLTexture
    ) {
        let drawableSize = SIMD2<Float>(Float(targetTexture.width), Float(targetTexture.height))
        encodeSdf(
            instances,
            into: targetTexture,
            drawableSize: drawableSize,
            presenting: drawable,
            waitForCompletion: false
        )
    }

    func captureSdfFrame(_ instances: [Instance], width: Int, height: Int) -> CapturedFrame {
        let targetTexture = makeOffscreenTexture(width: width, height: height)
        let drawableSize = SIMD2<Float>(Float(width), Float(height))
        encodeSdf(
            instances,
            into: targetTexture,
            drawableSize: drawableSize,
            presenting: nil,
            waitForCompletion: true
        )
        return readBack(targetTexture)
    }

    private func encodeSdf(
        _ instances: [Instance],
        into targetTexture: MTLTexture,
        drawableSize: SIMD2<Float>,
        presenting drawable: CAMetalDrawable?,
        waitForCompletion: Bool
    ) {
        if !instances.isEmpty {
            uploadInstances(instances)
        }

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = targetTexture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].clearColor = Self.clearColor
        renderPass.colorAttachments[0].storeAction = .store

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            fatalError("Failed to create a Metal command buffer")
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            fatalError("Failed to create a render command encoder")
        }

        if !instances.isEmpty {
            var size = drawableSize
            encoder.setRenderPipelineState(sdfPipelineState)
            encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            // The fragment shader declares a texture+sampler at index 0 for the
            // glyph branch; Metal API Validation requires them bound on any draw,
            // so they are set unconditionally even for an all-SDF frame (where the
            // sampler is never read).
            encoder.setFragmentTexture(atlas.texture, index: 0)
            encoder.setFragmentSamplerState(atlasSampler, index: 0)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: instances.count
            )
            drawCallCount += 1
        }
        encoder.endEncoding()

        if let drawable {
            commandBuffer.present(drawable)
        }
        committedFrameCount += 1
        commandBuffer.commit()

        if waitForCompletion {
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error {
                fatalError("SDF command buffer failed: \(error)")
            }
        }
    }

    private func uploadInstances(_ instances: [Instance]) {
        if instances.count > instanceCapacity {
            growInstanceBuffer(toFit: instances.count)
        }
        instances.withUnsafeBytes { source in
            instanceBuffer.contents().copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
    }

    private func growInstanceBuffer(toFit requiredCount: Int) {
        var newCapacity = instanceCapacity
        while newCapacity < requiredCount {
            newCapacity *= 2
        }
        guard let buffer = device.makeBuffer(
            length: newCapacity * MemoryLayout<Instance>.stride,
            options: .storageModeShared
        ) else {
            fatalError("Failed to grow the shared instance buffer to \(newCapacity) instances")
        }
        instanceBuffer = buffer
        instanceCapacity = newCapacity
    }

    private func makeOffscreenTexture(width: Int, height: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.drawablePixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("Failed to create an offscreen capture texture (\(width)x\(height))")
        }
        return texture
    }

    private func readBack(_ texture: MTLTexture) -> CapturedFrame {
        let bytesPerPixel = 4
        let bytesPerRow = texture.width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        let region = MTLRegionMake2D(0, 0, texture.width, texture.height)
        pixels.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: region,
                mipmapLevel: 0
            )
        }
        return CapturedFrame(width: texture.width, height: texture.height, bgraPixels: pixels)
    }
}
