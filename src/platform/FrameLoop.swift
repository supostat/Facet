import AppKit
import QuartzCore

// Drives one render callback per display refresh and holds NO Metal state.
// The display link is sourced from the window's content view (macOS 14+), which
// is ProMotion-aware and automatically tracks the view migrating between screens
// of different refresh rates — so no manual reattach on screen change is needed.
final class FrameLoop {
    private let onFrame: () -> Void
    private var displayLink: CADisplayLink?

    init(onFrame: @escaping () -> Void) {
        self.onFrame = onFrame
    }

    func start(view: NSView) {
        let displayLink = view.displayLink(target: self, selector: #selector(tick))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        onFrame()
    }
}
