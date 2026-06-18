import AppKit
import QuartzCore
import Metal

// Owns the NSWindow, its CAMetalLayer-backed content view, the Renderer, and the
// FrameLoop. Bridges AppKit window lifecycle (resize, backing-scale and screen
// changes, close) to drawable-size updates and the frame loop. Keeps the
// drawable sized in physical pixels so rendering is sharp at any backing scale.
final class Window: NSObject, NSWindowDelegate {
    private static let defaultContentSize = NSSize(width: 1024, height: 640)

    // Hardcoded reference scene supplied to the renderer every frame (§0a: the
    // renderer never builds a scene; this external supplier does). Removed when a
    // real scene source arrives in a later phase.
    private static let referenceScene = Instance.referenceScene

    private let window: NSWindow
    private let metalLayer: CAMetalLayer
    private let renderer: Renderer
    private let frameLoop: FrameLoop

    init(metallibPath: String) {
        renderer = Renderer(metallibPath: metallibPath)

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

        frameLoop = FrameLoop { [renderer, metalLayer] in
            guard let drawable = metalLayer.nextDrawable() else { return }
            renderer.drawSdfFrame(
                Self.referenceScene,
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
