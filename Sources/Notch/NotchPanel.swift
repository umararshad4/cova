import AppKit
import Combine
import SwiftUI

/// Keeps mouse handling to the island shape itself, so the fillet corners around it stay inert.
private final class IslandHostingView<Content: View>: NSHostingView<Content> {
    var hotRect: () -> CGRect = { .zero }
    var onScroll: ((NSEvent) -> Void)?
    var onHover: ((Bool) -> Void)?

    private var tracking: NSTrackingArea?

    /// Hover is tracked here rather than with SwiftUI's `.onHover`, which reports a spurious exit
    /// every time the hosting view resizes. Since the window now resizes *because* of hover, that
    /// produced an expand/collapse oscillation that read as flicker.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    // Enter/exit events are only a cheap trigger — the pointer's actual position is the source of
    // truth. Re-adding a tracking area (which every resize does) re-fires `mouseEntered` even when
    // the pointer is nowhere near, and since the window resizes *because* of hover, trusting the
    // event produced a self-sustaining expand/resize/enter loop.
    override func mouseEntered(with event: NSEvent) {
        guard pointerIsInside else { return }
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard !pointerIsInside else { return }
        onHover?(false)
    }

    private var pointerIsInside: Bool {
        guard let window else { return false }
        return window.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the superview's coordinate space.
        let local = superview.map { convert(point, from: $0) } ?? point
        return hotRect().contains(local) ? super.hitTest(point) : nil
    }

    /// Swipes are handled here rather than through a global event monitor. A global monitor needs
    /// Accessibility permission, and loses every gesture until the user grants it — but gestures
    /// only ever matter while the pointer is over the island, and events that land on our own
    /// window need no permission at all.
    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }
}

/// Borderless, non-activating panel pinned above the menu bar at the notch.
///
/// The window is sized to the island as it is *now*, not to the largest it can become. A fixed
/// expanded-size window leaves a dead zone over the menu bar whenever the island is collapsed:
/// returning nil from `hitTest` stops our views handling the click, but the window still swallows
/// it — AppKit does not forward it to whatever is underneath.
final class NotchPanel: NSPanel {
    /// Set by `AppDelegate`; receives scroll events that land on the island.
    var onScroll: ((NSEvent) -> Void)?

    private let coordinator: IslandCoordinator
    private var sizeObserver: AnyCancellable?
    private var shrink: DispatchWorkItem?

    /// Slack for the concave fillets that flow outward from the island's top corners.
    private static let filletSlack: CGFloat = 14

    init(coordinator: IslandCoordinator, screen: NSScreen) {
        self.coordinator = coordinator
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        // Above the menu bar (level 24). Anything at or below it renders behind.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = IslandHostingView(rootView: IslandView(coordinator: coordinator))
        host.hotRect = { [weak self] in self?.islandRect ?? .zero }
        host.onScroll = { [weak self] event in self?.onScroll?(event) }
        host.onHover = { [weak self] inside in
            // Grow before `hover` runs, not from inside it. Resizing the window re-adds the
            // tracking area, which re-fires enter/exit — doing that *during* the hover state
            // change is the self-sustaining expand/resize/enter oscillation this file exists to
            // avoid. Growing first means the hook below is already a no-op by the time it fires.
            if inside { self?.growForExpansion() }
            coordinator.hover(inside)
            if inside { self?.watchForExit() }
        }
        contentView = host

        // Covers the paths the block above cannot: tap-to-toggle, and a hover *delay*, where
        // expansion happens long after the pointer arrived. Idempotent — `growForExpansion`
        // returns without touching the frame once the window is already big enough.
        coordinator.onWillExpand = { [weak self] in self?.growForExpansion() }

        applyFrame(for: windowSize(), animated: false)
        orderFrontRegardless()

        // Follow the island's size so the window never covers more than the island does.
        sizeObserver = coordinator.objectWillChange.sink { [weak self] in
            // objectWillChange fires *before* the value updates; read it next tick.
            DispatchQueue.main.async { self?.syncSize() }
        }
    }

    /// Tracking-area exits are not guaranteed — a resize, a Space switch or a warped pointer can
    /// swallow them, and a missed exit leaves the island stuck open forever. While hovered, poll the
    /// real pointer position and collapse the moment it is outside. Costs nothing when not hovered.
    private var exitWatch: Heartbeat.Token?

    private func watchForExit() {
        guard exitWatch == nil else { return }
        exitWatch = Heartbeat.shared.subscribe(.fast) { [weak self] in
            guard let self else { return }
            // Generous margin so a pointer resting on the very edge does not chatter.
            guard !self.frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) else { return }
            self.stopWatchingForExit()
            self.coordinator.hover(false)
        }
    }

    private func stopWatchingForExit() {
        if let exitWatch { Heartbeat.shared.cancel(exitWatch) }
        exitWatch = nil
    }

    /// A borderless window is not key-eligible by default, which would block interaction.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Sizing

    private func windowSize() -> CGSize {
        let island = coordinator.currentSize
        return CGSize(
            width: island.width + Self.filletSlack * 2,
            height: island.height + Self.filletSlack
        )
    }

    /// Pre-emptively size the window for the expanded island, synchronously.
    private func growForExpansion() {
        let island = IslandCoordinator.expandedSize
        let target = CGSize(
            width: island.width + Self.filletSlack * 2,
            height: island.height + Self.filletSlack
        )
        guard target.width > frame.width || target.height > frame.height else { return }
        shrink?.cancel()
        shrink = nil
        applyFrame(for: target, animated: false)
    }

    private func syncSize() {
        let target = windowSize()
        guard target != frame.size else { return }

        shrink?.cancel()
        shrink = nil

        // Grow immediately — the pointer needs somewhere to land before the content expands.
        if target.width > frame.width || target.height > frame.height {
            applyFrame(for: target, animated: false)
            return
        }

        // Shrink only once the collapse animation has finished, or the island gets clipped mid-way.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.windowSize() == target else { return }
            self.applyFrame(for: target, animated: false)
        }
        shrink = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func applyFrame(for size: CGSize, animated: Bool) {
        let geometry = coordinator.geometry
        setFrame(
            CGRect(
                x: geometry.centerX - size.width / 2,
                y: geometry.topY - size.height,
                width: size.width,
                height: size.height
            ),
            display: true,
            animate: animated
        )
    }

    /// The island's bounds inside the content view, in the view's (bottom-left origin) space.
    private var islandRect: CGRect {
        guard let bounds = contentView?.bounds else { return .zero }
        let size = coordinator.currentSize
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Ordering out rather than hiding keeps the panel off the screen-capture and Space lists too.
    func setVisible(_ visible: Bool) {
        if visible {
            guard !isVisible else { return }
            orderFrontRegardless()
        } else if isVisible {
            orderOut(nil)
        }
    }

    func reposition(on screen: NSScreen) {
        applyFrame(for: windowSize(), animated: false)
    }
}
