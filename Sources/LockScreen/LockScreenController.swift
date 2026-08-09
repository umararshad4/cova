import AppKit
import SwiftUI

struct LockLifecycleState {
    enum Event {
        case locked
        case unlocked
        case willSleep
        case didWake(isLocked: Bool)
        case sessionBecameActive(isLocked: Bool)
    }

    private(set) var isLocked = false
    private(set) var isSleeping = false

    var shouldPresent: Bool { isLocked && !isSleeping }
    var suppressesMainPanel: Bool { isLocked || isSleeping }

    mutating func apply(_ event: Event) {
        switch event {
        case .locked:
            isLocked = true
        case .unlocked:
            isLocked = false
        case .willSleep:
            isSleeping = true
        case let .didWake(isLocked), let .sessionBecameActive(isLocked):
            isSleeping = false
            self.isLocked = isLocked
        }
    }
}

/// Renders the island on the login window by parking a panel in a private, high-level CGS Space —
/// the same technique the shipping Alcove uses (`CGSSpaceCreate`, `CGSSpaceSetAbsoluteLevel`,
/// `CGSAddWindowsToSpaces`, `CGSShowSpaces`).
///
/// This is the most dangerous code in the app. Alcove's author locked himself out of his Mac four
/// times building it. Three guardrails, none of them optional:
///
///  1. Disabled by default. Turn on with:
///       defaults write dev.local.tyland lockScreenEnabled -bool YES
///     Escape hatch, usable over SSH if the UI is unreachable:
///       defaults write dev.local.tyland lockScreenEnabled -bool NO && pkill -x Tyland
///  2. A watchdog force-tears-down the space shortly after unlock, even if the unlock
///     notification is missed.
///  3. Every private symbol is resolved at runtime; if any is missing the feature disables itself
///     rather than half-building a space it cannot destroy.
///
/// Before enabling: log in on a second admin account and confirm SSH works from another machine.
@MainActor
final class LockScreenController {
    private var panel: NSPanel?
    private var space: UInt64 = 0
    private var connection: Int32 = 0
    private var watchdog: Task<Void, Never>?
    private var pollToken: Heartbeat.Token?
    private var lifecycle = LockLifecycleState()

    private let coordinator: IslandCoordinator

    var onSuppressionChange: ((Bool) -> Void)?

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: "lockScreenEnabled") }

    /// All symbols must resolve, or we refuse to start.
    private var symbolsAvailable: Bool {
        Private.cgsMainConnectionID != nil
            && Private.cgsSpaceCreate != nil
            && Private.cgsSpaceDestroy != nil
            && Private.cgsSpaceSetAbsoluteLevel != nil
            && Private.cgsSpaceAddWindows != nil
            && Private.cgsShowSpaces != nil
            && Private.cgsHideSpaces != nil
    }

    init(coordinator: IslandCoordinator) {
        self.coordinator = coordinator
    }

    /// A compact media card. macOS already draws the clock and date on the lock screen, so this
    /// only carries what the system doesn't.
    private static func panelSize(for coordinator: IslandCoordinator) -> CGSize {
        CGSize(width: 470, height: 92)
    }

    /// Where the card's centre sits, as a fraction of screen height measured from the top.
    /// Nudge without rebuilding:
    ///   defaults write dev.local.tyland lockScreenPosition -float 0.72
    private static var verticalFraction: Double {
        let stored = UserDefaults.standard.double(forKey: "lockScreenPosition")
        return stored > 0 ? min(max(stored, 0.05), 0.95) : 0.72
    }

    func start() {
        if !isEnabled {
            Debug.log("lock screen: disabled (set lockScreenEnabled to enable)")
        } else if !symbolsAvailable {
            Debug.log("lock screen: private symbols unavailable, staying off")
        }

        let center = DistributedNotificationCenter.default()
        // `.deliverImmediately` is essential: by default distributed notifications are suspended
        // while an app is inactive, and this app is *always* inactive at the moment the screen
        // locks — so the lock notification would be queued and never acted on.
        center.addObserver(
            self, selector: #selector(screenLocked),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil,
            suspensionBehavior: .deliverImmediately
        )
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ] {
            workspaceCenter.addObserver(
                self, selector: #selector(systemWillSleep), name: name, object: nil
            )
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceCenter.addObserver(
                self, selector: #selector(systemDidWake), name: name, object: nil
            )
        }
        workspaceCenter.addObserver(
            self,
            selector: #selector(sessionBecameActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        center.addObserver(
            self, selector: #selector(screenUnlocked),
            name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil,
            suspensionBehavior: .deliverImmediately
        )
        // Belt and braces: the notification can be suppressed or missed entirely, so lock state is
        // also sampled on the shared heartbeat. This is the mechanism that actually has to work.
        pollToken = Heartbeat.shared.subscribe(.slow) { [weak self] in self?.pollLockState() }

        Debug.log("lock screen: armed")
        lifecycle.apply(.didWake(isLocked: Private.screenIsLocked))
        reconcile()

        // Diagnostic: present immediately without locking, then tear down.
        //   defaults write dev.local.tyland debugPresentLockScreen -bool YES
        if UserDefaults.standard.bool(forKey: "debugPresentLockScreen") {
            present()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                self?.teardown()
                Debug.log("lock screen: diagnostic teardown done")
            }
        }
    }

    private func pollLockState() {
        guard !lifecycle.isSleeping else { return }
        let locked = Private.screenIsLocked
        guard locked != lifecycle.isLocked else { return }
        Debug.log("lock screen: state changed, locked=\(locked)")
        lifecycle.apply(locked ? .locked : .unlocked)
        reconcile()
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let pollToken { Heartbeat.shared.cancel(pollToken) }
        pollToken = nil
        teardown()
    }

    // MARK: - Lock cycle

    @objc private func screenLocked() {
        lifecycle.apply(.locked)
        reconcile()
    }

    @objc private func screenUnlocked() {
        lifecycle.apply(.unlocked)
        reconcile()
    }

    @objc private func systemWillSleep() {
        lifecycle.apply(.willSleep)
        reconcile()
    }

    @objc private func systemDidWake() {
        lifecycle.apply(.didWake(isLocked: Private.screenIsLocked))
        reconcile()
    }

    @objc private func sessionBecameActive() {
        lifecycle.apply(.sessionBecameActive(isLocked: Private.screenIsLocked))
        reconcile()
    }

    private func reconcile() {
        onSuppressionChange?(lifecycle.suppressesMainPanel)
        guard lifecycle.shouldPresent else {
            teardown()
            return
        }
        guard isEnabled, symbolsAvailable else { return }
        present()
        startWatchdog()
    }

    private func present() {
        guard panel == nil,
              isEnabled,
              symbolsAvailable,
              let screen = NSScreen.main,
              let mainConnection = Private.cgsMainConnectionID,
              let spaceCreate = Private.cgsSpaceCreate,
              let setLevel = Private.cgsSpaceSetAbsoluteLevel,
              let addWindows = Private.cgsSpaceAddWindows,
              let showSpaces = Private.cgsShowSpaces
        else { return }

        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize(for: coordinator)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Transport buttons need clicks. `hitTest` keeps everything except the buttons inert, so
        // the card cannot swallow a click meant for the password field behind it.
        panel.ignoresMouseEvents = false
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let host = LockScreenHostingView(rootView: LockScreenView(coordinator: coordinator))
        panel.contentView = host

        let size = Self.panelSize(for: coordinator)
        let frame = screen.frame
        // AppKit's origin is bottom-left; the fraction is measured from the top.
        let centreY = frame.maxY - frame.height * Self.verticalFraction
        panel.setFrame(
            CGRect(
                x: frame.midX - size.width / 2,
                y: centreY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            display: true
        )
        panel.orderFrontRegardless()

        connection = mainConnection()
        // The literal 1 matters; nil returns 0 and nothing ever shows.
        space = spaceCreate(connection, 1, 0)
        guard space != 0 else {
            Debug.log("lock screen: space creation failed")
            panel.orderOut(nil)
            panel.close()
            connection = 0
            return
        }

        // Order matters: level, then show, then adopt the window.
        setLevel(connection, space, Private.lockScreenSpaceLevel)
        showSpaces(connection, [space] as CFArray)
        addWindows(connection, space, [panel.windowNumber] as CFArray, 7)

        self.panel = panel
        Debug.log("lock screen: presented in space \(space)")
    }

    /// Idempotent — safe to call from the unlock notification, the watchdog, and `stop()`.
    private func teardown() {
        watchdog?.cancel()
        watchdog = nil

        if space != 0 {
            Private.cgsHideSpaces?(connection, [space] as CFArray)
            Private.cgsSpaceDestroy?(connection, space)
            space = 0
        }

        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        connection = 0
    }

    /// Belt and braces: if the unlock notification never lands, poll the session state and tear
    /// down anyway. A private space that outlives the lock screen is what locks people out.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if !Private.screenIsLocked {
                    Debug.log("lock screen: watchdog tore down a stale space")
                    self.lifecycle.apply(.unlocked)
                    self.reconcile()
                    return
                }
            }
        }
    }
}

/// The current track, as a standalone card. No clock or date — macOS already draws those on the
/// lock screen, and duplicating them put this panel straight on top of the system time.
struct LockScreenView: View {
    @ObservedObject var coordinator: IslandCoordinator

    private var media: MediaState? {
        guard let media = coordinator.media, media.hasTrack else { return nil }
        return media
    }

    var body: some View {
        Group {
            if let media {
                HStack(spacing: 12) {
                    Artwork(image: media.artwork, size: 52, cornerRadius: 10)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(media.displayTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(media.artist)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)

                        // Display only — seeking by drag on the login window is not worth the
                        // extra interactive surface. Ticked for the same reason as the island scrubber — `progress` is
                        // extrapolated from a clock, so the bar needs a repaint to advance.
                        TimelineView(.animation(minimumInterval: 0.5, paused: !media.isPlaying)) { _ in
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.18))
                                    Capsule().fill(media.accent)
                                        .frame(width: max(0, geo.size.width * media.progress))
                                }
                            }
                        }
                        .frame(height: 3)
                        .padding(.top, 3)
                    }

                    HStack(spacing: 14) {
                        LockButton(symbol: "backward.fill", size: 13) {
                            coordinator.mediaCommand?(.previous)
                        }
                        LockButton(symbol: media.isPlaying ? "pause.fill" : "play.fill", size: 17) {
                            coordinator.mediaCommand?(.togglePlayPause)
                        }
                        LockButton(symbol: "forward.fill", size: 13) {
                            coordinator.mediaCommand?(.next)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.black.opacity(0.55))
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(
                                LinearGradient(colors: [media.accent.opacity(0.35), .clear],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Only the transport buttons accept clicks. Everything else in the lock-screen card passes
/// through, so the card cannot intercept a click meant for the login field behind it.
///
/// The rect is explicit rather than delegated to SwiftUI: `NSHostingView` reports *itself* as the
/// hit for any interactive SwiftUI content, so testing `hit === self` would have rejected the
/// buttons too and left them dead.
private final class LockScreenHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Width of the trailing strip the transport row occupies, plus a little slack.
        // A `static let` is not allowed on a generic type, so it lives here.
        let controlsWidth: CGFloat = 140
        let local = superview.map { convert(point, from: $0) } ?? point
        let controls = CGRect(
            x: bounds.maxX - controlsWidth,
            y: bounds.minY,
            width: controlsWidth,
            height: bounds.height
        )
        return controls.contains(local) ? super.hitTest(point) : nil
    }
}

/// A transport control sized for glancing at, with a visible press state.
private struct LockButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.white.opacity(pressed ? 0.6 : 0.9))
            .frame(width: size + 12, height: size + 10)
            .contentShape(Rectangle())
            .scaleEffect(pressed ? 0.88 : 1)
            .animation(.interpolatingSpring(stiffness: 520, damping: 22), value: pressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressed = true }
                    .onEnded { _ in
                        pressed = false
                        action()
                    }
            )
    }
}
