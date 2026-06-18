import AppKit
import Foundation
import Metal
import QuartzCore

// Bench harness for the SDF renderer. Modes:
//   --write-reference  headless: render the canonical SDF scenes and the glyph
//                      atlas dump, write their golden PNGs next to the snapshot
//                      tests, then exit.
//   --atlas            open the live atlas viewer: the ReferenceAtlas glyphs are
//                      laid out as a row of tinted quads sampled from the R8
//                      atlas texture, so a human can eye-check the rasterizer +
//                      packer + glyph shader end to end.
//   (default)          open the live editable SDF window so a human can tweak the
//                      selected instance's size/color/radius with the keyboard
//                      and eye-check the renderer's output frame by frame.
// The harness sits outside the production path and is the bench-side external
// scene supplier; it reuses the production Renderer and FrameLoop but owns its
// own editable window so the production Window stays a fixed-scene surface. The
// renderer still never builds a scene.
@main
struct RendererBench {
    // Canonical capture size for every golden. Matches the window content size
    // so the live eye-check and the headless goldens show the same composition.
    private static let referenceWidth = 1024
    private static let referenceHeight = 640

    private static let goldensDirectory = "tests/snapshots"

    static func main() {
        let metallibPath = MetallibLocator.resolve()

        if CommandLine.arguments.contains("--write-reference") {
            writeReferenceGoldens(metallibPath: metallibPath)
            return
        }

        if CommandLine.arguments.contains("--atlas") {
            runLiveAtlasWindow(metallibPath: metallibPath)
            return
        }

        runLiveWindow(metallibPath: metallibPath)
    }

    private static func writeReferenceGoldens(metallibPath: String) {
        let renderer = Renderer(metallibPath: metallibPath)
        let goldens: [(name: String, scene: [Instance])] = [
            ("sdf_reference_rects.png", Instance.referenceScene),
            ("sdf_radius_zero.png", Instance.radiusZeroScene),
            ("sdf_radius_half_side.png", Instance.radiusHalfSideScene),
            ("phase-3-shadow.png", Instance.shadowScene),
            ("phase-3-border.png", Instance.borderScene),
            ("phase-3-combined.png", Instance.combinedScene),
        ]

        // Text scenes are assembled from the renderer's own atlas via the shared
        // ReferenceText builders so the goldens are byte-identical to what
        // TextSnapshotTests renders from an atlas built the same deterministic way.
        let textGoldens: [(name: String, scene: [Instance])] = [
            (ReferenceText.referenceStringGoldenName, ReferenceText.referenceStringScene(atlas: renderer.atlas)),
            (ReferenceText.mixedFrameGoldenName, ReferenceText.mixedFrameScene(atlas: renderer.atlas)),
            (ReferenceText.twoColorsGoldenName, ReferenceText.twoColorsScene(atlas: renderer.atlas)),
        ]

        for golden in goldens + textGoldens {
            let frame = renderer.captureSdfFrame(
                golden.scene,
                width: referenceWidth,
                height: referenceHeight
            )
            let url = URL(fileURLWithPath: goldensDirectory).appendingPathComponent(golden.name)
            PngImage.write(
                bgraPixels: frame.bgraPixels,
                width: frame.width,
                height: frame.height,
                url: url
            )
            print("wrote \(golden.name)")
        }

        writeAtlasGolden(device: renderer.atlas.texture.device)
    }

    // The glyph-atlas golden: the deviceGray R8 dump of the fixed ReferenceAtlas
    // texture, in top-left atlas space (the orientation the rasterizer flips into
    // and AtlasSnapshotTests reads back). compareGray validates the test render
    // against this single-channel image.
    private static func writeAtlasGolden(device: MTLDevice) {
        let atlas = ReferenceAtlas.build(device: device)
        let url = URL(fileURLWithPath: goldensDirectory).appendingPathComponent(ReferenceAtlas.goldenName)
        AtlasInspector.writeTexturePng(atlas.texture, to: url)
        print("wrote \(ReferenceAtlas.goldenName)")
        print(AtlasInspector.machineDump(atlas.snapshot()))
    }

    private static func runLiveAtlasWindow(metallibPath: String) {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.activate()

        let window = AtlasViewerWindow(metallibPath: metallibPath)
        window.show()

        application.run()
    }

    private static func runLiveWindow(metallibPath: String) {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.activate()

        let window = BenchWindow(metallibPath: metallibPath)
        window.show()

        application.run()
    }
}

// The bench-side editable window. Mirrors the production Window's CAMetalLayer +
// FrameLoop wiring but, instead of a hardcoded immutable scene, holds a MUTABLE
// instance set the operator edits live from the keyboard. Each frame the current
// set is handed to the production Renderer, so what the eye sees is exactly what
// the renderer produces. Confined to the harness: production code is untouched.
private final class BenchWindow: NSObject, NSWindowDelegate {
    private static let contentSize = NSSize(width: 1024, height: 640)

    private let window: NSWindow
    private let metalLayer: CAMetalLayer
    private let renderer: Renderer
    private let frameLoop: FrameLoop
    private let editor: SceneEditor

    init(metallibPath: String) {
        renderer = Renderer(metallibPath: metallibPath)
        // The text overlay is built from the renderer's atlas so the operator can
        // eye-check the production glyph branch live; the editor toggles it on/off.
        let textOverlay = ReferenceText.referenceStringScene(atlas: renderer.atlas)
        editor = SceneEditor(instances: Instance.referenceScene, textOverlay: textOverlay)

        metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true

        let contentView = BenchContentView(
            frame: NSRect(origin: .zero, size: Self.contentSize),
            editor: editor
        )
        contentView.wantsLayer = true
        contentView.layer = metalLayer

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .resizable, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Facet — renderer bench"
        window.contentView = contentView
        window.center()

        frameLoop = FrameLoop { [renderer, metalLayer, editor] in
            guard let drawable = metalLayer.nextDrawable() else { return }
            renderer.drawSdfFrame(
                editor.instances,
                presentingTo: drawable,
                targetTexture: drawable.texture
            )
        }

        super.init()
        window.delegate = self
        updateDrawableSize()
        editor.printControls()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        guard let contentView = window.contentView else {
            fatalError("BenchWindow has no content view to source the display link from")
        }
        window.makeFirstResponder(contentView)
        frameLoop.start(view: contentView)
    }

    private func updateDrawableSize() {
        guard let contentView = window.contentView else {
            fatalError("BenchWindow has no content view to size the drawable against")
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

// First-responder content view: routes key presses to the SceneEditor so the
// operator can tweak the selected instance and watch the renderer react.
private final class BenchContentView: NSView {
    private let editor: SceneEditor

    init(frame: NSRect, editor: SceneEditor) {
        self.editor = editor
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BenchContentView is created in code only")
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers, let key = characters.first else {
            super.keyDown(with: event)
            return
        }
        if !editor.handle(key: key) {
            super.keyDown(with: event)
        }
    }
}

// The editable external instance set plus the live-control state machine. Owns a
// mutable [Instance] and a selection cursor; each key nudges one field of the
// selected instance by a fixed step so the operator can sweep sizes, colors, and
// radii and watch the SDF respond. Pure model state — no Metal, no AppKit views.
private final class SceneEditor {
    private var baseInstances: [Instance]
    private let textOverlay: [Instance]
    private var textVisible = false
    private var selection: Int = 0

    // The scene handed to the renderer: the editable SDF instances, plus the fixed
    // text overlay when toggled on, so SDF and glyph instances draw in one pass.
    var instances: [Instance] {
        textVisible ? baseInstances + textOverlay : baseInstances
    }

    private static let sizeStep: Float = 10
    private static let radiusStep: Float = 4
    private static let colorStep: Float = 0.05
    private static let offsetStep: Float = 4
    private static let blurStep: Float = 4
    private static let borderStep: Float = 2

    init(instances: [Instance], textOverlay: [Instance]) {
        precondition(!instances.isEmpty, "The bench scene must start with at least one instance")
        self.baseInstances = instances
        self.textOverlay = textOverlay
    }

    // Returns true if the key was a recognized control, false to let AppKit
    // handle it (so unmapped keys still beep / propagate normally).
    func handle(key: Character) -> Bool {
        switch key {
        case "\t": cycleSelection(); return true
        case "w": adjust(\.height, by: -Self.sizeStep); return true
        case "s": adjust(\.height, by: Self.sizeStep); return true
        case "a": adjust(\.width, by: -Self.sizeStep); return true
        case "d": adjust(\.width, by: Self.sizeStep); return true
        case "-", "_": adjust(\.cornerRadius, by: -Self.radiusStep); return true
        case "=", "+": adjust(\.cornerRadius, by: Self.radiusStep); return true
        case "r": adjust(\.colorR, by: Self.colorStep, clampUnit: true); return true
        case "g": adjust(\.colorG, by: Self.colorStep, clampUnit: true); return true
        case "b": adjust(\.colorB, by: Self.colorStep, clampUnit: true); return true
        case "R": adjust(\.colorR, by: -Self.colorStep, clampUnit: true); return true
        case "G": adjust(\.colorG, by: -Self.colorStep, clampUnit: true); return true
        case "B": adjust(\.colorB, by: -Self.colorStep, clampUnit: true); return true
        case "j": adjust(\.shadowOffsetX, by: -Self.offsetStep); return true
        case "l": adjust(\.shadowOffsetX, by: Self.offsetStep); return true
        case "i": adjust(\.shadowOffsetY, by: -Self.offsetStep); return true
        case "k": adjust(\.shadowOffsetY, by: Self.offsetStep); return true
        case "[": adjust(\.shadowBlurRadius, by: -Self.blurStep); return true
        case "]": adjust(\.shadowBlurRadius, by: Self.blurStep); return true
        case "o": adjust(\.shadowColorA, by: Self.colorStep, clampUnit: true); return true
        case "O": adjust(\.shadowColorA, by: -Self.colorStep, clampUnit: true); return true
        case "t": adjust(\.borderThickness, by: Self.borderStep); return true
        case "T": adjust(\.borderThickness, by: -Self.borderStep); return true
        case "n": adjust(\.borderColorA, by: Self.colorStep, clampUnit: true); return true
        case "N": adjust(\.borderColorA, by: -Self.colorStep, clampUnit: true); return true
        case "x": toggleText(); return true
        case "0": resetSelected(); return true
        default: return false
        }
    }

    private func toggleText() {
        textVisible.toggle()
        print(textVisible ? "text overlay ON" : "text overlay OFF")
    }

    func printControls() {
        print(
            """
            renderer-bench live controls (focus the window, then press):
              Tab       select next instance
              W / S     shrink / grow height
              A / D     shrink / grow width
              - / =     shrink / grow corner radius
              r/g/b     raise red / green / blue   (Shift to lower)
              i/j/k/l   nudge shadow offset up / left / down / right
              [ / ]     shrink / grow shadow blur radius
              o / O     raise / lower shadow alpha
              t / T     grow / shrink border thickness
              n / N     raise / lower border alpha
              x         toggle the glyph text overlay
              0         reset the selected instance to its reference value
            \(baseInstances.count) instances loaded; editing #\(selection).
            """
        )
    }

    private func cycleSelection() {
        selection = (selection + 1) % baseInstances.count
        print("editing instance #\(selection)")
    }

    private func resetSelected() {
        baseInstances[selection] = Instance.referenceScene[selection % Instance.referenceScene.count]
        print("reset instance #\(selection)")
    }

    private func adjust(
        _ field: WritableKeyPath<Instance, Float>,
        by delta: Float,
        clampUnit: Bool = false
    ) {
        var next = baseInstances[selection][keyPath: field] + delta
        if clampUnit {
            next = min(1, max(0, next))
        } else {
            next = max(0, next)
        }
        baseInstances[selection][keyPath: field] = next
    }
}
