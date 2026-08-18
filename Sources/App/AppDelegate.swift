import AppKit
import Combine
import MapKit
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
    private let islands = IslandGroup()
    private var statusItem: NSStatusItem?

    private let audio = AudioService()
    private let brightness = BrightnessService()
    private let battery = BatteryService()
    private let media = MediaService()
    private let tap = AudioTapService()
    private let calendar = CalendarService()
    private let bluetooth = BluetoothService()
    private let activities = ActivityService()
    private let settings = Settings.shared
    private let license = License.shared
    private let flags = FeatureFlags.shared
    /// Non-nil when the previous run died. Surfaced in Settings, never sent anywhere on its own.
    private(set) var previousCrash: String?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var lockScreen: LockScreenController?
    private let sound = SoundService()
    private let downloads = DownloadsService()
    private let routes = RouteService()
    private var runtime = RuntimePresentationState()
    private var presentationObservation: NSKeyValueObservation?
    private var hiddenWatch: Heartbeat.Token?
    private var settingsObservation: AnyCancellable?
    /// Which optional services are currently running, so toggling a widget on and off is idempotent.
    private var running: Set<String> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything else can crash. Also picks up whatever the *last* run left behind.
        Diagnostics.install()
        previousCrash = Diagnostics.collectPreviousCrash()
        if previousCrash != nil { Debug.log("previous run crashed; report captured") }
        if !Diagnostics.brokenSymbols.isEmpty {
            Debug.log("private symbols missing: \(Diagnostics.brokenSymbols.joined(separator: ", "))")
        }
        flags.start()
        license.refreshIfExpiringSoon()

        installStatusItem()
        rebuildIslands()
        // Onboarding runs *before* any service starts, so the first thing a new user sees is an
        // explanation rather than a stack of system alerts from an app with no visible window.
        Debug.log("onboarding completed=\(settings.hasCompletedOnboarding)")
        if settings.hasCompletedOnboarding {
            startServices()
        } else {
            showOnboarding()
        }
        runtime.hidesInFullScreen = settings.hideWhileInFullscreen

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // `objectWillChange` fires *before* the new value lands, so read it on the next turn of the
        // run loop. This replaces a `UserDefaults.didChangeNotification` observer, which also fired
        // for unrelated domains and only ever called `refreshPresentation()` — which is why nine
        // preferences silently needed a relaunch and five did nothing at all.
        settingsObservation = settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applySettings() }
        for name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ] {
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(activeAppChanged), name: name, object: nil
            )
        }
        // `open -a Tyland --args --settings` is the way back when the menu bar icon is hidden,
        // which is otherwise a soft brick that needs a Terminal `defaults write`.
        if CommandLine.arguments.contains("--settings") {
            openSettings()
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

    /// Which screen hosts the island.
    ///
    /// `NSScreen.main` is the screen with keyboard focus, which is not the same question: it made
    /// the island hop to whichever monitor was last clicked, and left `showOnDisplay` — a shipped
    /// preference — with nothing to act on.
    /// Which screens should carry an island. `allDisplays` is the reason a Mac mini or Studio user —
    /// who has no built-in display at all — can use this app.
    private func targetScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [] }

        // Free is the built-in display. Everything else — an external monitor, every monitor, and
        // therefore any Mac with no built-in display at all — is the paid tier. It is the sharpest
        // line available, and the segment no competitor serves.
        switch license.isPro ? settings.showOnDisplay : "builtInDisplay" {
        case "allDisplays":
            return screens
        case "activeDisplay":
            let pointer = NSEvent.mouseLocation
            let active = screens.first { NSMouseInRect(pointer, $0.frame, false) }
                ?? NSScreen.main
                ?? screens[0]
            return [active]
        default:
            // A real notch first; then the built-in panel; then whatever we have.
            let builtIn = screens.first { $0.safeAreaInsets.top > 0 }
                ?? screens.first { CGDisplayIsBuiltin(NotchGeometry.displayID(of: $0)) != 0 }
                ?? NSScreen.main
                ?? screens[0]
            return [builtIn]
        }
    }

    /// Creates, moves and destroys islands so the set on screen matches the preference. Safe to
    /// call at any time: existing displays keep their island (and everything it is showing).
    private func rebuildIslands() {
        let created = islands.reconcile(
            screens: targetScreens(),
            calibration: settings.calibration
        ) { screen, coordinator in
            coordinator.expandOnHover = self.settings.expandOnHover
            coordinator.hoverDuration = self.settings.hoverDuration
            // Design affordance: pins the island open so the expanded layout can be inspected.
            //   defaults write <bundle-id> debugForceExpanded -bool YES
            if UserDefaults.standard.bool(forKey: "debugForceExpanded") {
                coordinator.expandOnHover = false
                coordinator.toggle()
            }
            let panel = NotchPanel(coordinator: coordinator, screen: screen)
            // `hideFromScreenCapture`: keeps the island out of screenshots and shares.
            panel.sharingType = self.settings.hideFromScreenCapture ? .none : .readOnly
            Debug.log("island built on display \(NotchGeometry.displayID(of: screen)) frame=\(panel.frame)")
            return IslandGroup.Island(
                displayID: NotchGeometry.displayID(of: screen),
                coordinator: coordinator,
                panel: panel,
                gestures: GestureService()
            )
        }

        for island in created { wire(island) }
    }

    /// Per-island callbacks. Everything here is scoped to one display; anything global lives in
    /// `startServices`.
    private func wire(_ island: IslandGroup.Island) {
        let coordinator = island.coordinator
        let gestures = island.gestures

        coordinator.onPresentationChange = { [weak self] in self?.reconcileAudioTap() }
        coordinator.mediaCommand = { [weak self] command in self?.media.send(command) }
        coordinator.mediaSeek = { [weak self] seconds in self?.media.seek(to: seconds) }

        gestures.onSwipeDown = { coordinator.isExpanded ? () : coordinator.toggle() }
        gestures.onSwipeUp = { coordinator.collapse() }
        gestures.onSwipeLeft = { [weak self] in self?.media.send(.next) }
        gestures.onSwipeRight = { [weak self] in self?.media.send(.previous) }
        gestures.naturalMovement = settings.naturalMovement
        gestures.threshold = CGFloat(settings.gestureThreshold)
        gestures.cooldown = settings.gestureCooldown

        // Scroll events arrive from the panel they landed on; no monitor, no permission.
        island.panel.onScroll = { event in gestures.handle(event) }
    }

    /// Diagnostic hook, driven by `defaults write <bundle-id> debugSkipServices "a,b"`.
    /// Env vars do not survive LaunchServices, so this has to come from defaults.
    private static let skipped: Set<String> = Set(
        (UserDefaults.standard.string(forKey: "debugSkipServices") ?? "")
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    )
    private static func skip(_ name: String) -> Bool { skipped.contains(name) }

    /// The paid tier, expressed as one seam beside `skip`.
    ///
    /// Gating happens here — at the point a service is *started* — and never in the views. A view
    /// that has no coordinator field renders nothing already, so not starting the service is
    /// sufficient, and it means there is exactly one place to audit when the paywall goes live.
    ///
    /// While `License.bypassGate` is true this is the identity function.
    private func pro(_ wanted: Bool) -> Bool { wanted && license.isPro }

    /// A feature is live only if the user wants it, the licence allows it, and no remote flag has
    /// switched it off after an Apple update broke it. Fails open on every axis but the licence.
    private func live(_ wanted: Bool, _ feature: FeatureFlags.Feature) -> Bool {
        wanted && flags.isEnabled(feature)
    }

    private func startServices() {
        Debug.log("startServices")
        sound.isEnabled = settings.soundsEnabled
        sound.theme = settings.resolvedSoundTheme
        sound.volume = Float(settings.soundVolume)

        // Activity input fans out to every island. Per-display wiring lives in `wire(_:)`.
        audio.onChange = { [weak self] level, muted in
            guard let self else { return }
            self.islands.push(.volume(level: level, muted: muted))
            self.sound.play(.volumeTick)
        }
        audio.start()

        brightness.onDisplayChange = { [weak self] level in
            self?.islands.push(.brightness(level: level))
        }
        brightness.onKeyboardChange = { [weak self] level in
            self?.islands.push(.keyboardBacklight(level: level))
        }
        if !Self.skip("brightness") { brightness.start() }

        battery.onChange = { [weak self] state in
            self?.islands.each { $0.battery = state }
        }
        battery.onEvent = { [weak self] event in
            guard let self else { return }
            self.islands.push(.power(event))
            switch event {
            case .pluggedIn: self.sound.play(.plugIn)
            case .fullyCharged: self.sound.play(.fullyCharged)
            case .lowBattery: self.sound.play(.lowBattery)
            case .unplugged: break
            }
        }

        tap.onLevels = { [weak self] levels in
            self?.islands.setLevels(levels)
        }

        media.onUpdate = { [weak self] state in
            guard let self else { return }
            self.islands.each { $0.media = state }
            // The island carries music only while there is a track to show.
            if state.hasTrack {
                self.islands.push(.nowPlaying)
            } else {
                self.islands.withdraw(slot: "nowPlaying")
            }
            self.reconcileAudioTap()
        }
        media.preferredApp = settings.musicApp

        calendar.onChange = { [weak self] events in
            guard let self else { return }
            self.islands.each { $0.events = events }
            self.routes.upcomingEvents = events
        }

        routes.onAuthorizationChange = { status in
            Debug.log("route: location authorization now \(status.rawValue)")
        }
        routes.onChange = { [weak self] estimate in
            guard let self else { return }
            if let estimate {
                self.islands.push(.route(estimate))
            } else {
                self.islands.withdraw(slot: "route")
            }
        }

        activities.onFocus = { [weak self] name, symbol in
            guard let self else { return }
            if let name {
                self.islands.push(.focus(name: name, symbol: symbol))
            } else {
                self.islands.withdraw(slot: "focus")
            }
        }
        activities.onRecording = { [weak self] kind, active in
            guard let self else { return }
            if active {
                self.islands.push(.recording(kind))
            } else {
                self.islands.withdraw(slot: Activity.recording(kind).slot)
            }
            if kind == .microphone { self.sound.play(active ? .micUnmute : .micMute) }
        }

        downloads.onProgress = { [weak self] progress in
            guard let self else { return }
            self.islands.each { $0.download = progress.count > 0 ? progress : nil }
            if progress.count > 0 {
                self.islands.push(.download(progress))
            } else {
                self.islands.withdraw(slot: "download")
            }
        }
        downloads.onComplete = { [weak self] in
            self?.sound.play(.downloadComplete)
        }

        bluetooth.onEvent = { [weak self] device in
            guard let self else { return }
            self.islands.each { $0.device = device.connected ? device : nil }
            self.islands.push(.device(device))
            self.sound.play(device.connected ? .deviceConnect : .deviceDisconnect)

            // `warnOnLowConnectBattery` promised this and nothing implemented it: a device could
            // connect at 5% and the island said nothing.
            guard self.settings.warnOnLowConnectBattery,
                  device.connected,
                  let level = device.ringPercent,
                  level <= self.settings.deviceLowBatteryThreshold
            else { return }
            self.sound.play(.lowBattery)
            Debug.log("device \(device.name) low at \(level)%")
        }

        rebuildLockScreen()

        // Everything optional is started by reconcileServices(), driven off the Widgets tab.
        applySettings()
    }

    /// The lock-screen layer draws one card, on the primary island's coordinator. It is rebuilt
    /// when that island changes, because it holds a reference to the coordinator it renders.
    private func rebuildLockScreen() {
        guard let primary = islands.primary else { return }
        if let existing = lockScreen, existing.coordinator === primary.coordinator { return }
        lockScreen?.stop()
        running.remove("lockScreen")
        let controller = LockScreenController(coordinator: primary.coordinator)
        controller.onSuppressionChange = { [weak self] suppressed in
            self?.runtime.lifecycleSuppressed = suppressed
            self?.reconcileRuntime()
        }
        lockScreen = controller
    }

    private func showOnboarding() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Tyland"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView { [weak self] in
            guard let self else { return }
            self.settings.hasCompletedOnboarding = true
            self.onboardingWindow?.close()
            self.onboardingWindow = nil
            self.startServices()
        })
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window

        // Closing the window with the red button counts as "done" too — refusing to start until
        // someone presses the right button would be a worse first impression than any prompt.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.onboardingWindow != nil else { return }
                self.settings.hasCompletedOnboarding = true
                self.onboardingWindow = nil
                self.startServices()
            }
        }
    }

    @objc private func openSettings() {
        // Falls back to the synthetic notch when no island exists yet, so Settings can always open —
        // it is the only way back from a misconfiguration.
        let geometry = islands.primary?.coordinator.geometry
            ?? NotchGeometry.detect(screen: NSScreen.screens.first ?? NSScreen.main!, calibration: settings.calibration)
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
        window.contentView = NSHostingView(rootView: SettingsView(geometry: geometry))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    @objc private func contactSupport() {
        Diagnostics.composeSupportEmail(crash: previousCrash)
    }

    @objc private func activeAppChanged() {
        refreshPresentation()
    }

    /// Pushes every preference into whoever owns it. Called at launch and on every settings change,
    /// so "changes apply on relaunch" stops being true of anything except the menu bar icon.
    private func applySettings() {
        // Adding or removing a display target, or changing the notch calibration, both land here.
        rebuildIslands()
        rebuildLockScreen()

        islands.each { coordinator in
            coordinator.expandOnHover = settings.expandOnHover
            coordinator.hoverDuration = settings.hoverDuration
            coordinator.hudDuration = settings.hudDismissDelay
            coordinator.powerDuration = settings.powerDismissDelay
            coordinator.deviceDuration = settings.deviceDismissDelay
            coordinator.particlesEnabled = settings.showParticles
            coordinator.useAccentColor = settings.useAccentColorOnGestures
        }

        islands.setSharingType(settings.hideFromScreenCapture ? .none : .readOnly)

        sound.isEnabled = settings.soundsEnabled
        sound.theme = settings.resolvedSoundTheme
        sound.volume = Float(settings.soundVolume)

        for island in islands.islands {
            island.gestures.naturalMovement = settings.naturalMovement
            island.gestures.threshold = CGFloat(settings.gestureThreshold)
            island.gestures.cooldown = settings.gestureCooldown
        }

        battery.lowThreshold = settings.lowBatteryThreshold

        calendar.lookaheadHours = settings.calendarLookaheadHours
        calendar.eventLimit = settings.calendarEventLimit

        routes.bufferMinutes = settings.routeBufferMinutes
        routes.urgentMinutes = settings.routeUrgentMinutes
        routes.transportType = Self.transportType(settings.routeTransportType)

        downloads.readBrowserTotals = settings.readBrowserDownloadTotals
        // ~/Downloads is always watched; extra folders are Pro.
        downloads.folders = pro(true) ? settings.downloadFolders.map { URL(fileURLWithPath: $0) } : []

        // Both are only read inside `start()`, so a change needs a real restart.
        let wantsFallback = !flags.isEnabled(.mediaHelper)
        if media.preferredApp != settings.musicApp || media.forceFallback != wantsFallback {
            media.preferredApp = settings.musicApp
            media.forceFallback = wantsFallback
            if running.contains("media") { media.restart() }
        }

        refreshStatusItem()
        reconcileServices()
        refreshPresentation()
    }

    private static func transportType(_ raw: String) -> MKDirectionsTransportType {
        switch raw {
        case "walking": return .walking
        case "transit": return .transit
        default: return .automobile
        }
    }

    /// Starts and stops the optional services to match the Widgets tab. Turning a widget off also
    /// withdraws its slot, so a live activity cannot linger on screen after its source is gone.
    private func reconcileServices() {
        let islands = self.islands

        setRunning("media", settings.showNowPlaying && !Self.skip("media"),
                   start: { self.media.start() },
                   stop: { self.media.stop(); islands.each { $0.media = nil }; islands.withdraw(slot: "nowPlaying") })

        setRunning("battery", settings.showBattery,
                   start: { self.battery.start() },
                   stop: { self.battery.stop(); islands.each { $0.battery = nil }; islands.withdraw(slot: "power") })

        setRunning("calendar", pro(settings.showCalendar) && !Self.skip("calendar"),
                   start: { self.calendar.start() },
                   stop: { self.calendar.stop(); islands.each { $0.events = [] }; self.routes.upcomingEvents = [] })

        setRunning("routes", live(pro(settings.showCalendar && settings.showRoute), .routes) && !Self.skip("routes"),
                   start: { self.routes.start() },
                   stop: { self.routes.stop(); islands.withdraw(slot: "route") })

        // These two are deferred at launch: the first read of ~/Downloads and IOBluetooth
        // registration each block on their own consent prompt, and nothing else should wait.
        setRunning("downloads", settings.showDownloads && !Self.skip("downloads"),
                   start: { self.startDeferred("downloads", after: .milliseconds(300)) { self.downloads.start() } },
                   stop: { self.downloads.stop(); islands.each { $0.download = nil }; islands.withdraw(slot: "download") })

        setRunning("bluetooth", settings.showBluetooth && !Self.skip("bluetooth"),
                   start: { self.startDeferred("bluetooth", after: .milliseconds(600)) { self.bluetooth.start() } },
                   stop: { self.bluetooth.stop(); islands.each { $0.device = nil }; islands.withdraw(slot: "device") })

        // The lock screen is the feature most likely to need switching off remotely: it uses
        // private CGS Space APIs and a bad macOS interaction can put a window over the login field.
        setRunning("lockScreen", live(pro(settings.lockScreenEnabled), .lockScreen),
                   start: { self.lockScreen?.start() },
                   stop: { self.lockScreen?.stop() })

        let wantsActivities = (settings.showFocus || settings.showRecording) && !Self.skip("activities")
        setRunning("activities", wantsActivities,
                   start: { self.activities.start() },
                   stop: { self.activities.stop() })
        if !settings.showFocus { islands.withdraw(slot: "focus") }
        if !settings.showRecording {
            for kind in RecordingKind.allCases { islands.withdraw(slot: Activity.recording(kind).slot) }
        }
    }

    /// Runs `body` shortly, unless the widget was switched off again in the meantime.
    private func startDeferred(_ name: String, after delay: Duration, _ body: @escaping () -> Void) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.running.contains(name) else { return }
            body()
        }
    }

    private func setRunning(_ name: String, _ wanted: Bool, start: () -> Void, stop: () -> Void) {
        if wanted, !running.contains(name) {
            running.insert(name)
            Debug.log("starting \(name)")
            start()
        } else if !wanted, running.contains(name) {
            running.remove(name)
            Debug.log("stopping \(name)")
            stop()
        }
    }

    private func refreshStatusItem() {
        if settings.hideMenuBarIcon, statusItem != nil {
            NSStatusBar.system.removeStatusItem(statusItem!)
            statusItem = nil
        } else if !settings.hideMenuBarIcon, statusItem == nil {
            installStatusItem()
        }
    }

    private func refreshPresentation() {
        // Scoped to the island's own display: a fullscreen video on a second monitor must not
        // order the island out on the built-in one.
        // Scoped to the primary island's display. With islands on several screens the honest
        // question is per-panel, but hiding is a single runtime flag; the primary display is the
        // one the user is most likely to be looking at.
        runtime.isFullScreen = Private.activeSpaceIsFullScreen(
            onDisplay: islands.primary?.coordinator.geometry.displayID ?? 0
        )
            ?? NSApp.currentSystemPresentationOptions.contains(.fullScreen)
        runtime.hidesInFullScreen = settings.hideWhileInFullscreen
        reconcileRuntime()
    }

    private func reconcileRuntime() {
        guard !islands.isEmpty else { return }
        if runtime.isHidden { islands.collapse() }
        islands.each { $0.effectsActive = runtime.effectsActive }
        islands.setVisible(!runtime.isHidden)
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

    /// The tap, its private aggregate device, the ~90 Hz IOProc and the 20 Hz publish timer used to
    /// run whenever a track was playing — including while the island was expanded (album art, no
    /// waveform), while a volume HUD or a download covered Now Playing, and while the island was
    /// bare. Gate it on what is actually on screen instead; it is the cheapest energy win here.
    private func reconcileAudioTap() {
        guard !islands.isEmpty else { return }
        // One tap feeds every island, so it runs while *any* of them is drawing a waveform.
        if runtime.effectsActive, media.state.isPlaying, live(pro(settings.showWaveform), .audioTap),
           islands.anyWaveformVisible {
            tap.start()
        } else {
            tap.stop()
            islands.setLevels([])
        }
    }

    /// A display was attached, removed, or rearranged. Also the retry path if no screen was
    /// resolvable at launch, which is how a login-item start on a sleeping display recovers.
    @objc private func screensChanged() {
        rebuildIslands()
        rebuildLockScreen()
        guard !islands.isEmpty else { return }
        reconcileRuntime()
    }

    private func installStatusItem() {
        // Honour hideMenuBarIcon. Escape hatch, since this is the only way to reach Settings:
        //   defaults write <bundle-id> hideMenuBarIcon -bool NO && open -a Tyland
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
        // Prefilled with version, macOS build and which private symbols still resolve — so a bug
        // report arrives with the facts instead of "it stopped working".
        menu.addItem(withTitle: "Contact Support…", action: #selector(contactSupport), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tyland", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }
}
