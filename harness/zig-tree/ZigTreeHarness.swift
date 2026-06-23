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
            writeMeasureSceneGolden(metallibPath: metallibPath)
            return
        }

        if CommandLine.arguments.contains("--measure") {
            printMeasureScene(metallibPath: metallibPath)
            return
        }

        runLiveWindow(metallibPath: metallibPath)
    }

    // КТ-2 Ф14/14b: build the SEPARATE measure scene through a Renderer-backed seam,
    // install BOTH upward Core Text callbacks BEFORE producing (the install-order
    // invariant), produce once — which measures AND shapes the text leaf into legible
    // glyphs — and print the fit-content container's seam-measured main extent plus
    // the shape crossing count. The shape callback needs the renderer's live Atlas,
    // so this drives the measure scene through the production Renderer + the C
    // exports (Bridge is hardwired to the Phase-13 reference tree).
    private static func printMeasureScene(metallibPath: String) {
        let renderer = Renderer(metallibPath: metallibPath)
        let scene = produceMeasureScene(renderer: renderer)
        defer { facet_seam_destroy(scene.handle) }

        let containerMain = facet_seam_node_laid_out_main(scene.handle, scene.rootId + ReferenceZigTree.measureLabelContainerIdOffset)
        let measureCrossings = facet_seam_measure_crossings(scene.handle)
        let shapeCrossings = facet_seam_shape_crossings(scene.handle)
        print("measure scene: \"\(ReferenceZigTree.measureString)\" at \(ReferenceZigTree.measureFontSize)pt")
        print("  fit-content container hugs a measured main of \(containerMain)px after \(measureCrossings) measure crossing(s)")
        print("  shaped \(scene.instanceCount - 2) glyph instance(s) after \(shapeCrossings) shape crossing(s)")
    }

    // Renders the measure scene's legible Core Text glyphs and writes the Phase-14b
    // text golden. The scene IS the Zig facet_seam_build_measure_tree driven through
    // both upward seams, so the committed golden is byte-identical to the e2e render
    // by construction (the КТ-2 eye-check: the §0a real-text legibility view).
    private static func writeMeasureSceneGolden(metallibPath: String) {
        let renderer = Renderer(metallibPath: metallibPath)
        let scene = produceMeasureScene(renderer: renderer)
        defer { facet_seam_destroy(scene.handle) }

        let frame = renderer.captureSdfFrame(
            instanceCount: scene.instanceCount,
            width: ReferenceZigTree.width,
            height: ReferenceZigTree.height
        )
        let url = URL(fileURLWithPath: "tests/snapshots").appendingPathComponent(ReferenceZigTree.phase14bTextGoldenName)
        PngImage.write(bgraPixels: frame.bgraPixels, width: frame.width, height: frame.height, url: url)
        print("wrote \(ReferenceZigTree.phase14bTextGoldenName)")
    }

    // The driven measure scene: the seam handle, its root id, and the produced
    // instance count, written into the renderer's shared buffer. Both upward
    // callbacks are installed before the produce (the install-order invariant); the
    // shape callback reads the renderer's live Atlas.
    private struct DrivenMeasureScene {
        let handle: UnsafeMutableRawPointer
        let rootId: UInt32
        let instanceCount: Int
    }

    private static func produceMeasureScene(renderer: Renderer) -> DrivenMeasureScene {
        guard let handle = facet_seam_create() else {
            fatalError("facet_seam_create returned null")
        }
        let measureStatus = facet_seam_set_measure_callback(handle, facetMeasureText)
        precondition(measureStatus == 0, "facet_seam_set_measure_callback rejected the callback (status \(measureStatus))")
        let shapeStatus = facet_seam_set_shape_callback(handle, makeFacetShapeText(atlas: renderer.atlas))
        precondition(shapeStatus == 0, "facet_seam_set_shape_callback rejected the callback (status \(shapeStatus))")

        let rootId = facet_seam_build_measure_tree(handle)
        precondition(rootId != UInt32.max, "facet_seam_build_measure_tree failed")

        let base = renderer.sharedInstanceBufferBaseAddress.assumingMemoryBound(to: FacetInstance.self)
        _ = facet_seam_set_base_pointer(handle, base, UInt32(renderer.sharedInstanceCapacity))
        let count = facet_seam_give_instances(handle, rootId, Float(ReferenceZigTree.width), Float(ReferenceZigTree.height))
        precondition(count >= 0, "the measure scene produce overflowed or failed (status \(count))")

        return DrivenMeasureScene(handle: handle, rootId: rootId, instanceCount: Int(count))
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
