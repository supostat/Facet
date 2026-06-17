import AppKit

// Process entry point for the windowed app. A bare executable (no .app bundle /
// Info.plist) must explicitly become a regular, activated application before the
// run loop starts, otherwise it never receives key/mouse events. Order matters:
// set the activation policy, then activate, then bring the window up and run.
@main
struct AppMain {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.activate()

        let window = Window()
        window.show()

        application.run()
    }
}
