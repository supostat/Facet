import AppKit
import Foundation
import Metal
import QuartzCore

// КТ-2: the Zig-tree -> screen harness (spec §0a). The tree is built by Zig code
// (no React, no bridge mutation protocol) and displayed through the real
// seam-driven Window, with a key handler that routes into the seam's reference
// mutation so an operator can press a key and watch the next frame reflect the
// change by eye — the eye-check for the most dangerous two-language seam.
//
// Modes:
//   --write-reference  headless: drive the Zig seam through the Renderer's
//                      count-based capture to regenerate the two phase-13 goldens
//                      (before + after mutation), then exit.
//   --measure          headless: build the Ф14 MEASURE scene through the seam,
//                      install the real Core Text callback, produce, and print the
//                      fit-content container's seam-measured dimensions (the sized
//                      SDF box hugging the text — legible glyphs deferred to 14b).
//   (default)          open the live window; press M to mutate the reference tree.
//
// Named ZigTreeHarness.swift, NOT main.swift: a file literally named main.swift is
// top-level code and cannot carry @main (precedent: RendererBench.swift).
@main
struct ZigTreeHarness {
    static func main() {
        let metallibPath = MetallibLocator.resolve()

        if CommandLine.arguments.contains("--write-reference") {
            writeReferenceGoldens(metallibPath: metallibPath)
            return
        }

        if CommandLine.arguments.contains("--measure") {
            printMeasureScene()
            return
        }

        runLiveWindow(metallibPath: metallibPath)
    }

    // КТ-2 Ф14: build the SEPARATE measure scene, install the production Core Text
    // callback BEFORE producing (the install-order invariant), produce once, and
    // print the fit-content label container's seam-measured main extent — the SDF
    // box that hugs the measured text. No window and no golden: nothing legible
    // renders until the Phase-14b glyph-injection half lands, so this surfaces the
    // measured GEOMETRY as data, the eye-check of the upward measure seam.
    private static func printMeasureScene() {
        guard let handle = facet_seam_create() else {
            fatalError("facet_seam_create returned null")
        }
        defer { facet_seam_destroy(handle) }

        let status = facet_seam_set_measure_callback(handle, facetMeasureText)
        precondition(status == 0, "facet_seam_set_measure_callback rejected the callback (status \(status))")

        let rootId = facet_seam_build_measure_tree(handle)
        precondition(rootId != UInt32.max, "facet_seam_build_measure_tree failed")

        var buffer = [FacetInstance](repeating: FacetInstance(), count: 16)
        buffer.withUnsafeMutableBufferPointer { pointer in
            _ = facet_seam_set_base_pointer(handle, pointer.baseAddress, UInt32(pointer.count))
            _ = facet_seam_give_instances(handle, rootId, Float(ReferenceZigTree.width), Float(ReferenceZigTree.height))
        }

        let containerMain = facet_seam_node_laid_out_main(handle, rootId + ReferenceZigTree.measureLabelContainerIdOffset)
        let crossings = facet_seam_measure_crossings(handle)
        print("measure scene: \"\(ReferenceZigTree.measureString)\" at \(ReferenceZigTree.measureFontSize)pt")
        print("  fit-content container hugs a measured main of \(containerMain)px after \(crossings) seam crossing(s)")
    }

    // Drives the Zig seam straight into the renderer's shared buffer and captures
    // the before-mutation and after-mutation frames, writing both goldens. The
    // writer and the e2e test drive the SAME Zig build_reference_tree, so the
    // goldens are byte-identical to the test render by construction.
    private static func writeReferenceGoldens(metallibPath: String) {
        let renderer = Renderer(metallibPath: metallibPath)
        let bridge = Bridge(renderer: renderer)

        let beforeCount = bridge.produceInstances(
            drawableWidth: Float(ReferenceZigTree.width),
            drawableHeight: Float(ReferenceZigTree.height)
        )
        writeGolden(renderer: renderer, instanceCount: beforeCount, name: ReferenceZigTree.beforeGoldenName)

        bridge.mutate()
        let afterCount = bridge.produceInstances(
            drawableWidth: Float(ReferenceZigTree.width),
            drawableHeight: Float(ReferenceZigTree.height)
        )
        writeGolden(renderer: renderer, instanceCount: afterCount, name: ReferenceZigTree.afterGoldenName)
    }

    private static func writeGolden(renderer: Renderer, instanceCount: Int, name: String) {
        let frame = renderer.captureSdfFrame(
            instanceCount: instanceCount,
            width: ReferenceZigTree.width,
            height: ReferenceZigTree.height
        )
        let url = URL(fileURLWithPath: "tests/snapshots").appendingPathComponent(name)
        PngImage.write(bgraPixels: frame.bgraPixels, width: frame.width, height: frame.height, url: url)
        print("wrote \(name)")
    }

    private static func runLiveWindow(metallibPath: String) {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.activate()

        let window = ZigTreeWindow(metallibPath: metallibPath)
        window.show()

        application.run()
    }
}

// The live КТ-2 window: a seam-driven CAMetalLayer surface whose tree is the Zig
// reference tree. A key press (M) mutates the reference tree through the seam; the
// next frame's has-changed gate picks it up and re-produces, so the operator sees
// the change reflected. Mirrors the production Window's wiring but routes key
// events into the seam so the two-language path is exercised by hand.
private final class ZigTreeWindow: NSObject, NSWindowDelegate {
    private static let contentSize = NSSize(width: 1024, height: 640)

    private let window: NSWindow
    private let metalLayer: CAMetalLayer
    private let renderer: Renderer
    private let bridge: Bridge
    private let frameLoop: FrameLoop

    init(metallibPath: String) {
        renderer = Renderer(metallibPath: metallibPath)
        bridge = Bridge(renderer: renderer)

        metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true

        let contentView = ZigTreeContentView(frame: NSRect(origin: .zero, size: Self.contentSize), bridge: bridge)
        contentView.wantsLayer = true
        contentView.layer = metalLayer

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .resizable, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Facet — Zig tree harness (press M to mutate)"
        window.contentView = contentView
        window.center()

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
        print("Zig tree harness: press M to mutate the reference tree and watch the next frame update.")
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        guard let contentView = window.contentView else {
            fatalError("ZigTreeWindow has no content view to source the display link from")
        }
        window.makeFirstResponder(contentView)
        frameLoop.start(view: contentView)
    }

    private func updateDrawableSize() {
        guard let contentView = window.contentView else {
            fatalError("ZigTreeWindow has no content view to size the drawable against")
        }
        let scale = window.backingScaleFactor
        metalLayer.contentsScale = scale
        let bounds = contentView.bounds
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
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

// First-responder content view: an M key press mutates the reference tree through
// the seam so the operator can eye-check that a tree change reflects on the next
// frame.
private final class ZigTreeContentView: NSView {
    private let bridge: Bridge

    init(frame: NSRect, bridge: Bridge) {
        self.bridge = bridge
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ZigTreeContentView is created in code only")
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers, let key = characters.first else {
            super.keyDown(with: event)
            return
        }
        if key == "m" || key == "M" {
            bridge.mutate()
            print("mutated the reference tree")
        } else {
            super.keyDown(with: event)
        }
    }
}
