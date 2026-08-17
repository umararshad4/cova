import AppKit
import SwiftUI

struct RuntimePresentationState {
    var lifecycleSuppressed = false
    var isFullScreen = false
    var hidesInFullScreen = true

    var isHidden: Bool { lifecycleSuppressed || (hidesInFullScreen && isFullScreen) }
    var effectsActive: Bool { !isHidden }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: IslandCoordinator?
    private var panel: NotchPanel?
    private var statusItem: NSStatusItem?

    private let audio = AudioService()
    private let brightness = BrightnessService()
    private let battery = BatteryService()
    private let media = MediaService()
    private let tap = AudioTapService()
    private let calendar = CalendarService()
    private let gestures = GestureService()
    private let bluetooth = BluetoothService()
    private let activities = ActivityService()
    private let settings = Settings.shared
    private var settingsWindow: NSWindow?
    private var lockScreen: LockScreenController?
    private let sound = SoundService()
    private let downloads = DownloadsService()
    private let routes = RouteService()
    private var runtime = RuntimePresentationState()
    private var presentationObservation: NSKeyValueObservation?
    private var hiddenWatch: Heartbeat.Token?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        buildPanel()
        startServices()
        runtime.hidesInFullScreen = settings.hideWhileInFullscreen

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
        for name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ] {
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(activeAppChanged), name: name, object: nil
            )
        }
        presentationObservation = NSApp.observe(
            \.currentSystemPresentationOptions,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshPresentation() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        audio.stop()
        brightness.stop()
        battery.stop()
        media.stop()
        tap.stop()
        calendar.stop()
        gestures.stop()
        bluetooth.stop()
        activities.stop()
        lockScreen?.stop()
        sound.stop()
        downloads.stop()
        routes.stop()
        presentationObservation?.invalidate()
        presentationObservation = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func buildPanel() {
        guard let screen = NSScreen.main else { return }
        let coordinator = IslandCoordinator(geometry: .detect(screen: screen, calibration: settings.calibration))
        coordinator.expandOnHover = settings.expandOnHover
        coordinator.hoverDuration = settings.hoverDuration
        // Design affordance: pins the island open so the expanded layout can be inspected.
        //   defaults write dev.local.tyland debugForceExpanded -bool YES
        if UserDefaults.standard.bool(forKey: "debugForceExpanded") {
            coordinator.expandOnHover = false
            coordinator.toggle()
        }
        self.coordinator = coordinator
        let panel = NotchPanel(coordinator: coordinator, screen: screen)
        // Alcove's `hideFromScreenCapture`: keeps the island out of screenshots and shares.
        panel.sharingType = settings.hideFromScreenCapture ? .none : .readOnly
        self.panel = panel
        Debug.log("panel built, visible=\(panel.isVisible) frame=\(panel.frame)")
    }

    /// Diagnostic hook, driven by `defaults write dev.local.tyland debugSkipServices "a,b"`.
    /// Env vars do not survive LaunchServices, so this has to come from defaults.
    private static let skipped: Set<String> = Set(
        (UserDefaults.standard.string(forKey: "debugSkipServices") ?? "")
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    )
    private static func skip(_ name: String) -> Bool { skipped.contains(name) }

    private func startServices() {
        guard let coordinator else { return }

        sound.isEnabled = settings.soundsEnabled
        sound.theme = settings.resolvedSoundTheme
        sound.volume = Float(settings.soundVolume)

        audio.onChange = { [weak self] level, muted in
            coordinator.push(.volume(level: level, muted: muted))
            self?.sound.play(.volumeTick)
        }
        audio.start()

        brightness.onDisplayChange = { level in
            coordinator.push(.brightness(level: level))
        }
        brightness.onKeyboardChange = { level in
            coordinator.push(.keyboardBacklight(level: level))
        }
        if !Self.skip("brightness") { brightness.start() }

        battery.onChange = { state in
            coordinator.battery = state
        }
        battery.onEvent = { [weak self] event in
            coordinator.push(.power(event))
            switch event {
            case .pluggedIn: self?.sound.play(.plugIn)
            case .fullyCharged: self?.sound.play(.fullyCharged)
            case .lowBattery: self?.sound.play(.lowBattery)
            case .unplugged: break
            }
        }
        battery.start()

        tap.onLevels = { levels in
            coordinator.levelStore.levels = levels
        }

        media.onUpdate = { [weak self] state in
            coordinator.media = state
            // The island carries music only while there is a track to show.
            if state.hasTrack {
                coordinator.push(.nowPlaying)
            } else {
                coordinator.withdraw(slot: "nowPlaying")
            }
            self?.reconcileAudioTap()
        }
        coordinator.mediaCommand = { [weak self] command in
            self?.media.send(command)
        }
        coordinator.mediaSeek = { [weak self] seconds in
            self?.media.seek(to: seconds)
        }
        media.preferredApp = settings.musicApp
        if !Self.skip("media") { media.start() }

        calendar.onChange = { [weak self] events in
            coordinator.events = events
            self?.routes.upcomingEvents = events
        }
        Debug.log("starting lock screen")
        let lockScreen = LockScreenController(coordinator: coordinator)
        lockScreen.onSuppressionChange = { [weak self] suppressed in
            self?.runtime.lifecycleSuppressed = suppressed
            self?.reconcileRuntime()
        }
        lockScreen.start()
        self.lockScreen = lockScreen

        Debug.log("starting calendar"); calendar.start()


        routes.onChange = { estimate in
            if let estimate {
                coordinator.push(.route(estimate))
            } else {
                coordinator.withdraw(slot: "route")
            }
        }
        Debug.log("starting routes"); if !Self.skip("routes") { routes.start() }

        gestures.onSwipeDown = { coordinator.isExpanded ? () : coordinator.toggle() }
        gestures.onSwipeUp = { coordinator.collapse() }
        gestures.onSwipeLeft = { [weak self] in self?.media.send(.next) }
        gestures.onSwipeRight = { [weak self] in self?.media.send(.previous) }
        // Scroll events now arrive from the panel; no monitor, no permission.
        panel?.onScroll = { [weak self] event in self?.gestures.handle(event) }


        activities.onFocus = { name, symbol in
            if let name {
                coordinator.push(.focus(name: name, symbol: symbol))
            } else {
                coordinator.withdraw(slot: "focus")
            }
        }
        activities.onRecording = { [weak self] kind, active in
            if active {
                coordinator.push(.recording(kind))
            } else {
                coordinator.withdraw(slot: "recording")
            }
            if kind == .microphone { self?.sound.play(active ? .micUnmute : .micMute) }
        }
        Debug.log("starting activities"); if !Self.skip("activities") { activities.start() }

        downloads.onProgress = { progress in
            coordinator.download = progress.count > 0 ? progress : nil
            if progress.count > 0 {
                coordinator.push(.download(progress))
            } else {
                coordinator.withdraw(slot: "download")
            }
        }
        downloads.onComplete = { [weak self] in
            self?.sound.play(.downloadComplete)
        }
        // Deferred so a slow first read of ~/Downloads cannot delay anything else.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            Debug.log("starting downloads")
            if !Self.skip("downloads") { self.downloads.start() }
        }

        // Bluetooth starts last and deferred. Belt and braces: IOBluetooth registration can be slow,
        // and nothing else should wait on it.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self else { return }
            Debug.log("starting bluetooth")
            // IOBluetooth registration blocks on its own consent prompt; never on the main actor.
        bluetooth.onEvent = { [weak self] device in
                coordinator.device = device.connected ? device : nil
                coordinator.push(.device(device))
                self?.sound.play(device.connected ? .deviceConnect : .deviceDisconnect)
            }
            if !Self.skip("bluetooth") { self.bluetooth.start() }
        }
    }

    @objc private func openSettings() {
        guard let coordinator else { return }
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tyland Settings"
        window.contentView = NSHostingView(rootView: SettingsView(geometry: coordinator.geometry))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    @objc private func activeAppChanged() {
        refreshPresentation()
    }

    @objc private func settingsChanged() {
        refreshPresentation()
    }

    private func refreshPresentation() {
        runtime.isFullScreen = Private.activeSpaceIsFullScreen
            ?? NSApp.currentSystemPresentationOptions.contains(.fullScreen)
        runtime.hidesInFullScreen = settings.hideWhileInFullscreen
        reconcileRuntime()
    }

    private func reconcileRuntime() {
        guard let coordinator else { return }
        if runtime.isHidden { coordinator.collapse() }
        coordinator.effectsActive = runtime.effectsActive
        panel?.setVisible(!runtime.isHidden)
        if !Self.skip("activities") {
            activities.setPollingEnabled(runtime.effectsActive)
        }
        reconcileAudioTap()
        watchWhileHidden()
        Debug.log(
            "runtime: hidden=\(runtime.isHidden) fullscreen=\(runtime.isFullScreen) "
                + "suppressed=\(runtime.lifecycleSuppressed)"
        )
    }

    /// Hiding is driven entirely by notifications, and a missed or mistimed one latches: a Space
    /// switch reports the *outgoing* Space as current if it is sampled during the animation, so the
    /// island stays ordered out on the desktop it just arrived at until something else happens to
    /// fire. Nothing re-checked, which is why it could sit missing on one Space for days. While
    /// hidden, re-sample on the shared heartbeat; while visible there is no timer at all.
    private func watchWhileHidden() {
        if runtime.isHidden, hiddenWatch == nil {
            hiddenWatch = Heartbeat.shared.subscribe(.slow) { [weak self] in
                self?.refreshPresentation()
            }
        } else if !runtime.isHidden, let token = hiddenWatch {
            Heartbeat.shared.cancel(token)
            hiddenWatch = nil
        }
    }

    private func reconcileAudioTap() {
        guard let coordinator else { return }
        if runtime.effectsActive, media.state.isPlaying, settings.showWaveform {
            tap.start()
        } else {
            tap.stop()
            coordinator.levelStore.levels = []
        }
    }

    @objc private func screensChanged() {
        guard let screen = NSScreen.main, let coordinator else { return }
        coordinator.geometry = .detect(screen: screen, calibration: settings.calibration)
        panel?.reposition(on: screen)
    }

    private func installStatusItem() {
        // Honour hideMenuBarIcon. Escape hatch, since this is the only way to reach Settings:
        //   defaults write dev.local.tyland hideMenuBarIcon -bool NO && open -a Tyland
        guard !settings.hideMenuBarIcon else {
            Debug.log("menu bar icon hidden by setting")
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.topthird.inset.filled",
            accessibilityDescription: "Tyland"
        )
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tyland", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }
}
