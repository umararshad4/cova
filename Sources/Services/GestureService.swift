import AppKit

/// Two-finger trackpad swipes over the notch.
///
/// Events are delivered by `NotchPanel` when they land on the island — no Accessibility, no Input
/// Monitoring, no global monitor. Alcove's constraint was "no full keyboard access"; this goes
/// further and needs no permission at all.
@MainActor
final class GestureService {
    var onSwipeDown: (() -> Void)?
    var onSwipeUp: (() -> Void)?
    var onSwipeLeft: (() -> Void)?
    var onSwipeRight: (() -> Void)?

    private var monitor: Any?
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var lastFired = Date.distantPast

    /// Scroll distance before a swipe counts, and how long before another can fire.
    var threshold: CGFloat = 18
    var cooldown: TimeInterval = 0.45
    /// Follows the trackpad's own natural-scroll setting. With natural scrolling on, a two-finger
    /// pull *down* reports a positive deltaY; with it off, the sign is inverted and every gesture
    /// in the app ran backwards — which is exactly what the shipped toggle promised to fix and
    /// never did, because nothing read it.
    var naturalMovement = true

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Called by `NotchPanel` for scroll events that land on the island. No permission needed.
    func handle(_ event: NSEvent) {
        // Mouse wheels produce coarse deltas and would fire constantly; trackpads only.
        guard event.hasPreciseScrollingDeltas else { return }
        guard Date().timeIntervalSince(lastFired) > cooldown else { return }

        // A new gesture starts fresh so momentum from the last one doesn't leak in.
        if event.phase == .began { accumulatedX = 0; accumulatedY = 0 }

        accumulatedY += event.scrollingDeltaY
        accumulatedX += event.scrollingDeltaX

        let sign: CGFloat = naturalMovement ? 1 : -1
        if abs(accumulatedY) >= threshold, abs(accumulatedY) > abs(accumulatedX) {
            accumulatedY * sign > 0 ? onSwipeDown?() : onSwipeUp?()
            reset()
        } else if abs(accumulatedX) >= threshold {
            accumulatedX * sign > 0 ? onSwipeRight?() : onSwipeLeft?()
            reset()
        }
    }

    private func reset() {
        accumulatedX = 0
        accumulatedY = 0
        lastFired = Date()
    }
}
