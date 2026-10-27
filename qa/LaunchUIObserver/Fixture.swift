import AppKit

// Explicit QA target only. The observer never launches this application or Cadence.
@main
enum Fixture {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.run()
    }
}
