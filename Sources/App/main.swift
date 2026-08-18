import AppKit

// NSApplication.delegate is weak, so the delegate needs an owner that outlives setup.
nonisolated(unsafe) private var retainedDelegate: AnyObject?

if CommandLine.arguments.contains("--self-test") {
    MainActor.assumeIsolated { runSelfTests() }
    exit(0)
}

// Two copies running at once — the one still in ~/Downloads and the one in /Applications — each
// build a panel, each spawn a com.apple.tyland.mediahelper child, and both contend for the
// lock-screen CGS space. An in-place updater makes a double launch more likely, not less.
if let identifier = Bundle.main.bundleIdentifier {
    let mine = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        .filter { $0.processIdentifier != mine }
    if let existing = others.first {
        FileHandle.standardError.write(
            "Tyland is already running (pid \(existing.processIdentifier))\n".data(using: .utf8)!
        )
        existing.activate()
        exit(0)
    }
}

let app = NSApplication.shared

// Only the *setup* runs inside `assumeIsolated`. `app.run()` must stay outside it: the run loop
// never returns, so nesting it here would leave the main actor permanently occupied by a single
// job — and every `Task { @MainActor }` in the app would queue behind it and never execute.
// That silently broke weather fetches, deferred service startup and lock-screen teardown.
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    retainedDelegate = delegate
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
}

app.run()
