import AppKit

/// Every island currently on screen — one per display the user asked for.
///
/// Each display owns a full `IslandCoordinator` rather than sharing one. Displays disagree about
/// geometry (a real notch on the built-in panel, a synthetic one on a 27-inch monitor), and hover
/// and expansion are naturally per-display: pointing at the external island should not open the
/// one on the laptop. Sharing a coordinator would have forced both to be true.
///
/// Activity input fans out; `AppDelegate` pushes once and every island shows it.
@MainActor
final class IslandGroup {
    struct Island {
        let displayID: CGDirectDisplayID
        let coordinator: IslandCoordinator
        let panel: NotchPanel
        /// Per-island, because the accumulators are stateful — one shared service would interleave
        /// two hands on two trackpads into a single nonsense gesture.
        let gestures: GestureService
    }

    private(set) var islands: [Island] = []

    /// The island the rest of the app treats as canonical: settings geometry, the lock screen, and
    /// the display whose fullscreen state decides hiding.
    var primary: Island? { islands.first }
    var isEmpty: Bool { islands.isEmpty }
    var coordinators: [IslandCoordinator] { islands.map(\.coordinator) }

    // MARK: - Activity input

    func push(_ activity: Activity) {
        for island in islands { island.coordinator.push(activity) }
    }

    func withdraw(slot: String) {
        for island in islands { island.coordinator.withdraw(slot: slot) }
    }

    func each(_ body: (IslandCoordinator) -> Void) {
        for island in islands { body(island.coordinator) }
    }

    func collapse() {
        for island in islands { island.coordinator.collapse() }
    }

    var anyExpanded: Bool { islands.contains { $0.coordinator.isExpanded } }

    /// Whether any island is currently drawing a waveform — what decides if the audio tap runs.
    var anyWaveformVisible: Bool { islands.contains { $0.coordinator.waveformIsVisible } }

    func setLevels(_ levels: [Float]) {
        for island in islands { island.coordinator.levelStore.levels = levels }
    }

    func setVisible(_ visible: Bool) {
        for island in islands { island.panel.setVisible(visible) }
    }

    func setSharingType(_ type: NSWindow.SharingType) {
        for island in islands where island.panel.sharingType != type {
            island.panel.sharingType = type
        }
    }

    // MARK: - Lifecycle

    /// Brings the set of islands in line with `screens`, keeping the ones that are still wanted.
    ///
    /// Returns the islands it created, so the caller can wire their per-island callbacks.
    @discardableResult
    func reconcile(
        screens: [NSScreen],
        calibration: NotchGeometry.Calibration,
        make: (NSScreen, IslandCoordinator) -> Island
    ) -> [Island] {
        let wanted = screens.map { (NotchGeometry.displayID(of: $0), $0) }
        let wantedIDs = Set(wanted.map(\.0))

        for island in islands where !wantedIDs.contains(island.displayID) {
            island.panel.setVisible(false)
            island.panel.orderOut(nil)
            island.gestures.stop()
        }
        islands.removeAll { !wantedIDs.contains($0.displayID) }

        var created: [Island] = []
        for (displayID, screen) in wanted {
            if let existing = islands.first(where: { $0.displayID == displayID }) {
                let geometry = NotchGeometry.detect(screen: screen, calibration: calibration)
                if geometry != existing.coordinator.geometry {
                    existing.coordinator.geometry = geometry
                    existing.panel.reposition(on: screen)
                }
                continue
            }
            let coordinator = IslandCoordinator(
                geometry: .detect(screen: screen, calibration: calibration)
            )
            if let source = primary?.coordinator { coordinator.adopt(from: source) }
            let island = make(screen, coordinator)
            islands.append(island)
            created.append(island)
        }

        // Keep a stable order so `primary` does not wander between reconciles.
        islands.sort { $0.displayID < $1.displayID }
        return created
    }

    func removeAll() {
        for island in islands {
            island.panel.setVisible(false)
            island.panel.orderOut(nil)
            island.gestures.stop()
        }
        islands.removeAll()
    }
}
