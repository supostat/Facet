import Metal
import QuartzCore

struct CapturedFrame {
    let width: Int
    let height: Int
    let bgraPixels: [UInt8]
}

// Owns the Metal device and the single command queue, and draws one empty
// clear pass per frame. Phase 1 builds no scene: the per-frame entry is shaped
// so a later phase adds an external scene parameter and an instanced draw
// without restructuring (the renderer is "given a target, draw it"; it never
// builds the scene itself).
final class Renderer {
    // Channel values are exact multiples of 1/255, so the float->BGRA8 mapping
    // is lossless and the snapshot test can assert exact bytes.
    static let clearColor = MTLClearColor(
        red: 12.0 / 255.0,
        green: 18.0 / 255.0,
        blue: 28.0 / 255.0,
        alpha: 1.0
    )

    private static let drawablePixelFormat: MTLPixelFormat = .bgra8Unorm

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    // Machine-observable metric: incremented at the single commit() call site,
    // asserted == 1 per frame by the snapshot/metric test.
    private(set) var committedFrameCount: Int = 0

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is unavailable: MTLCreateSystemDefaultDevice returned nil")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("Failed to create a Metal command queue")
        }
        self.device = device
        self.commandQueue = commandQueue
    }

    func drawClearFrame(presentingTo drawable: CAMetalDrawable, targetTexture: MTLTexture) {
        encodeClear(into: targetTexture, presenting: drawable, waitForCompletion: false)
    }

    func captureClearFrame(width: Int, height: Int) -> CapturedFrame {
        let targetTexture = makeOffscreenTexture(width: width, height: height)
        encodeClear(into: targetTexture, presenting: nil, waitForCompletion: true)
        return readBack(targetTexture)
    }

    private func encodeClear(
        into targetTexture: MTLTexture,
        presenting drawable: CAMetalDrawable?,
        waitForCompletion: Bool
    ) {
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
        encoder.endEncoding()

        if let drawable {
            commandBuffer.present(drawable)
        }
        committedFrameCount += 1
        commandBuffer.commit()

        if waitForCompletion {
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error {
                fatalError("Clear-frame command buffer failed: \(error)")
            }
        }
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
