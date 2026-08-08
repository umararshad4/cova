import Foundation

/// One timer source for the whole app.
///
/// Weather, downloads, screen-recording, ETA, brightness and camera all want their own timer.
/// Five more `Timer`s is how a 0.25% idle becomes 5%, so everything subscribes here instead.
/// Timers only exist while something is subscribed — an app with no subscribers has no wakeups.
@MainActor
final class Heartbeat {
    static let shared = Heartbeat()

    enum Rate {
        case fast   // 250 ms — brightness sampling, particle stepping
        case slow   // 2 s   — camera, screen recording, cheap polls

        var interval: TimeInterval {
            switch self {
            case .fast: return 0.25
            case .slow: return 2.0
            }
        }
    }

    struct Token: Hashable {
        fileprivate let id: UUID
        fileprivate let rate: Rate?
        fileprivate let interval: TimeInterval?

        static func == (a: Token, b: Token) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private var fast: [UUID: () -> Void] = [:]
    private var slow: [UUID: () -> Void] = [:]
    private var fastTimer: Timer?
    private var slowTimer: Timer?

    /// Minute-scale work keeps its own timer per interval, since there are few of them.
    private var scheduled: [UUID: Timer] = [:]

    private init() {}

    @discardableResult
    func subscribe(_ rate: Rate, _ block: @escaping () -> Void) -> Token {
        let id = UUID()
        switch rate {
        case .fast:
            fast[id] = block
            startFastIfNeeded()
        case .slow:
            slow[id] = block
            startSlowIfNeeded()
        }
        return Token(id: id, rate: rate, interval: nil)
    }

    /// For work measured in minutes (weather refresh, ETA recompute).
    @discardableResult
    func schedule(every interval: TimeInterval, fireImmediately: Bool = true,
                  _ block: @escaping () -> Void) -> Token {
        let id = UUID()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in block() }
        }
        RunLoop.main.add(timer, forMode: .common)
        // Minute-scale work is never urgent; let the OS batch the wakeup.
        timer.tolerance = interval * 0.1
        scheduled[id] = timer
        if fireImmediately { block() }
        return Token(id: id, rate: nil, interval: interval)
    }

    func cancel(_ token: Token) {
        switch token.rate {
        case .fast:
            fast[token.id] = nil
            if fast.isEmpty { fastTimer?.invalidate(); fastTimer = nil }
        case .slow:
            slow[token.id] = nil
            if slow.isEmpty { slowTimer?.invalidate(); slowTimer = nil }
        case nil:
            scheduled[token.id]?.invalidate()
            scheduled[token.id] = nil
        }
    }

    // MARK: - Timers

    private func startFastIfNeeded() {
        guard fastTimer == nil else { return }
        let timer = Timer(timeInterval: Rate.fast.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick(\.fast) }
        }
        // .common so ticks continue while a menu or drag is tracking.
        RunLoop.main.add(timer, forMode: .common)
        // Even 20% slack lets the OS coalesce these with other wakeups; nothing here needs
        // sub-frame accuracy.
        timer.tolerance = Rate.fast.interval * 0.2
        fastTimer = timer
    }

    private func startSlowIfNeeded() {
        guard slowTimer == nil else { return }
        let timer = Timer(timeInterval: Rate.slow.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick(\.slow) }
        }
        RunLoop.main.add(timer, forMode: .common)
        // Slow work is never urgent; let the OS batch it with other wakeups.
        timer.tolerance = 0.5
        slowTimer = timer
    }

    private func tick(_ keyPath: KeyPath<Heartbeat, [UUID: () -> Void]>) {
        // Snapshot: a subscriber may cancel itself from inside its own block.
        for block in self[keyPath: keyPath].values { block() }
    }
}
