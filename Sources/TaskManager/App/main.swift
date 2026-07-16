import AppKit

// A file named `main.swift` is top-level code, so `@main` cannot be used here.
// SE-0343 isolates top-level code to the MainActor only in Swift 6 language mode;
// this target builds in v5 mode, so the isolated singletons below need an explicit
// assumeIsolated. It is sound — top-level code does run on the main thread.

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate

MainActor.assumeIsolated {
    AppState.shared.applyAppearance()
    SystemMonitor.shared.start(interval: AppState.shared.updateInterval)
}

app.run()
