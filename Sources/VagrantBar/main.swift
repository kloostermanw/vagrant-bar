import AppKit

// Top-level code runs on the main thread; tell the compiler so it can create the
// main-actor-isolated AppDelegate.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
