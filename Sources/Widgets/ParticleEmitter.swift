import SwiftUI

/// Small particle system for island flourishes — charging sparkle, device-connect burst.
///
/// One `Canvas` and a fixed-capacity array of structs. No per-particle SwiftUI views, and no
/// allocation while running: dead particles are recycled in place. Steps on the shared fast
/// heartbeat, and only while it is actually on screen.
@MainActor
final class ParticleField: ObservableObject {
    struct Particle {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var vx: CGFloat = 0
        var vy: CGFloat = 0
        var life: CGFloat = 0      // 1 → 0
        var decay: CGFloat = 0.04
        var size: CGFloat = 2

        var isAlive: Bool { life > 0 }
    }

    enum Style {
        case sparkle   // drifts upward, warm — charging
        case burst     // radial pop — device connected
    }

    /// Bumping `version` is what tells SwiftUI to redraw; the array itself is mutated in place.
    @Published private(set) var version: Int = 0

    private(set) var particles: [Particle]
    private var token: Heartbeat.Token?
    private var style: Style = .sparkle
    private var bounds: CGSize = .zero
    private var emitBudget = 0

    init(capacity: Int = 40) {
        particles = Array(repeating: Particle(), count: capacity)
    }

    func start(style: Style, in size: CGSize) {
        self.style = style
        bounds = size
        emitBudget = style == .burst ? particles.count : 0
        guard token == nil else { return }
        token = Heartbeat.shared.subscribe(.fast) { [weak self] in self?.step() }
    }

    func stop() {
        if let token { Heartbeat.shared.cancel(token) }
        token = nil
        for index in particles.indices { particles[index].life = 0 }
        version &+= 1
    }

    private func step() {
        var anyAlive = false

        // Sparkle trickles; burst spends its whole budget at once.
        let spawn = style == .sparkle ? 2 : emitBudget
        emitBudget = 0
        var spawned = 0

        for index in particles.indices {
            if particles[index].isAlive {
                particles[index].x += particles[index].vx
                particles[index].y += particles[index].vy
                particles[index].life -= particles[index].decay
                if style == .sparkle { particles[index].vy += 0.02 }  // slight gravity
                anyAlive = anyAlive || particles[index].isAlive
            } else if spawned < spawn {
                particles[index] = makeParticle(index: index)
                spawned += 1
                anyAlive = true
            }
        }

        version &+= 1
        // A burst that has fully died should stop costing anything.
        if style == .burst, !anyAlive { stop() }
    }

    /// Deterministic pseudo-randomness from the index and tick — no `Math.random` churn, and it
    /// keeps the field reproducible for tests.
    private func makeParticle(index: Int) -> Particle {
        let seed = CGFloat((index &* 2_654_435_761 &+ version &* 40_503) % 1_000) / 1_000
        let seed2 = CGFloat((index &* 40_503 &+ version &* 2_654_435_761) % 1_000) / 1_000

        switch style {
        case .sparkle:
            return Particle(
                x: bounds.width * seed,
                y: bounds.height,
                vx: (seed2 - 0.5) * 0.6,
                vy: -0.9 - seed2 * 0.7,
                life: 1,
                decay: 0.035 + seed2 * 0.02,
                size: 1.2 + seed * 1.6
            )
        case .burst:
            let angle = seed * .pi * 2
            let speed = 0.8 + seed2 * 1.6
            return Particle(
                x: bounds.width / 2,
                y: bounds.height / 2,
                vx: cos(angle) * speed,
                vy: sin(angle) * speed,
                life: 1,
                decay: 0.05 + seed2 * 0.03,
                size: 1 + seed2 * 1.4
            )
        }
    }
}

struct ParticleEmitter: View {
    @ObservedObject var field: ParticleField
    var tint: Color = .white

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            _ = field.version  // read so the Canvas re-renders on each step
            for particle in field.particles where particle.isAlive {
                let rect = CGRect(
                    x: particle.x - particle.size / 2,
                    y: particle.y - particle.size / 2,
                    width: particle.size,
                    height: particle.size
                )
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(tint.opacity(Double(particle.life) * 0.9))
                )
            }
        }
        .allowsHitTesting(false)
    }
}
