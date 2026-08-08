import AppKit
import Combine
import SwiftUI

/// Keeps mouse handling to the island shape itself, so the fillet corners around it stay inert.
private final class IslandHostingView<Content: View>: NSHostingView<Content> {
    var hotRect: () -> CGRect = { .zero }
    var onScroll: ((NSEvent) -> Void)?
    var onHover: ((Bool) -> Void)?
    /// Whether the pointer is over the island right now. Supplied by the panel in screen space.
    var pointerIsHot: () -> Bool = { false }

    private var tracking: NSTrackingArea?
    private var hovering = false

    /// Hover is tracked here rather than with SwiftUI's `.onHover`, which reports a spurious exit
    /// every time the hosting view resizes. Since the window resizes *because* of hover, that
    /// produced an expand/collapse oscillation that read as flicker.
    ///
    /// `.mouseMoved` matters as much as enter/exit: the window is wider than the island, so the
    /// pointer can cross from the fillet slack onto the island without ever entering the view.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { syncHover() }
    override func mouseMoved(with event: NSEvent) { syncHover() }
    override func mouseExited(with event: NSEvent) { syncHover() }

    /// The one funnel every hover signal goes through, and the reason the island no longer flickers.
    ///
    /// Events are only a hint to re-check; the pointer's position against the island is the truth.
    /// Every resize re-adds the tracking area and re-fires enter/exit, and expanding resizes the
    /// window — so trusting the events directly meant hover drove a resize that re-triggered hover.
    /// Deduping against the last reported state makes those echoes no-ops, including the ones that
    /// arrive re-entrantly from inside `onHover` itself.
    func syncHover() {
        let hot = pointerIsHot()
        guard hot != hovering else { return }
        hovering = hot
        onHover?(hot)
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
    private let host: IslandHostingView<IslandView>
    private var sizeObserver: AnyCancellable?
    private var shrink: DispatchWorkItem?

    /// Slack for the concave fillets that flow outward from the island's top corners.
    private static let filletSlack: CGFloat = 14

    /// Margin around the island's edge, so a pointer resting on the boundary does not chatter.
    private static let hoverSlop: CGFloat = 4

    /// The island's own bounds in screen coordinates — the hover hot zone.
    ///
    /// Derived from the geometry and the island size, never from the window frame. The window is
    /// larger than the island and grows *because* of hover, so measuring hover against it made the
    /// hot zone a function of its own output: one sweep past the notch left the window expanded,
    /// and from then on the island opened for a pointer anywhere in the top-centre of the screen.
    static func hotZone(island: CGSize, geometry: NotchGeometry) -> CGRect {
        CGRect(
            x: geometry.centerX - island.width / 2,
            y: geometry.topY - island.height,
            width: island.width,
            height: island.height
        )
        .insetBy(dx: -hoverSlop, dy: -hoverSlop)
    }

    init(coordinator: IslandCoordinator, screen: NSScreen) {
        self.coordinator = coordinator
        self.host = IslandHostingView(rootView: IslandView(coordinator: coordinator))
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

        host.hotRect = { [weak self] in self?.islandRect ?? .zero }
        host.onScroll = { [weak self] event in self?.onScroll?(event) }
        host.pointerIsHot = { [weak self] in
            guard let self else { return false }
            return Self.hotZone(island: self.coordinator.currentSize, geometry: self.coordinator.geometry)
                .contains(NSEvent.mouseLocation)
        }
        host.onHover = { [weak self] inside in
            coordinator.hover(inside)
            inside ? self?.watchForExit() : self?.stopWatchingForExit()
        }
        contentView = host

        // The single place the window grows, so it only ever happens when the island is actually
        // about to expand — hover, tap-to-toggle and a hover *delay* all route through here. Growing
        // on hover instead stranded the window at expanded size whenever the delay was cancelled or
        // `expandOnHover` was off, because nothing published and nothing shrank it back.
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
        // Through the same funnel as the events, so the safety net can never disagree with them.
        exitWatch = Heartbeat.shared.subscribe(.fast) { [weak self] in self?.host.syncHover() }
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
