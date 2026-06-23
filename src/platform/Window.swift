import AppKit
import QuartzCore
import Metal

// Owns the NSWindow, its CAMetalLayer-backed content view, the Renderer, and the
// FrameLoop. Bridges AppKit window lifecycle (resize, backing-scale and screen
// changes, close) to drawable-size updates and the frame loop. Keeps the
// drawable sized in physical pixels so rendering is sharp at any backing scale.
final class Window: NSObject, NSWindowDelegate {
    private static let defaultContentSize = NSSize(width: 1024, height: 640)

    private let window: NSWindow
    private let metalLayer: CAMetalLayer
    private let renderer: Renderer
    private let bridge: Bridge
    private let frameLoop: FrameLoop

    init(metallibPath: String) {
        renderer = Renderer(metallibPath: metallibPath)
        // The Zig seam builds the initial tree and writes instances straight into
        // the renderer's shared buffer; Window no longer carries a hardcoded scene
        // (the Block III stitching removes it — the tree is the scene source now).
        bridge = Bridge(renderer: renderer)

        metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true

        let contentView = NSView(frame: NSRect(origin: .zero, size: Self.defaultContentSize))
        contentView.wantsLayer = true
        contentView.layer = metalLayer

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .resizable, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Facet"
        window.contentView = contentView
        window.center()

        // The seam-driven frame: on a changed frame, ask Zig to produce the instance
        // array straight into the shared buffer and draw the produced count; on a
        // static frame, re-bind the SAME buffer and re-draw the prior count with NO
        // produce. The static redraw relies on the .storageModeShared buffer
        // persisting and never reallocating outside a produce that re-hands the base
        // — a no-produce frame must re-bind exactly the base the last produce wrote.
        frameLoop = FrameLoop { [renderer, metalLayer, bridge] in
            guard let drawable = metalLayer.nextDrawable() else { return }
            let drawableSize = metalLayer.drawableSize
            let count: Int
            if bridge.hasChanged() {
                count = bridge.produceInstances(
                    drawableWidth: Float(drawableSize.width),
                    drawableHeight: Float(drawableSize.height)
                )
            } else {
                count = bridge.lastInstanceCount
            }
            renderer.drawSdfFrame(
                instanceCount: count,
                presentingTo: drawable,
                targetTexture: drawable.texture
            )
        }

        super.init()
        window.delegate = self
        updateDrawableSize()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        guard let contentView = window.contentView else {
            fatalError("Window has no content view to source the display link from")
        }
        frameLoop.start(view: contentView)
    }

    private func updateDrawableSize() {
        guard let contentView = window.contentView else {
            fatalError("Window has no content view to size the drawable against")
        }
        let scale = window.backingScaleFactor
        metalLayer.contentsScale = scale
        let bounds = contentView.bounds
        metalLayer.drawableSize = CGSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )
    }

    func windowDidResize(_ notification: Notification) {
        updateDrawableSize()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        updateDrawableSize()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updateDrawableSize()
    }

    func windowWillClose(_ notification: Notification) {
        frameLoop.stop()
    }
}
