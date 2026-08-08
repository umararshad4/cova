import AppKit

/// Where the island lives on a given screen, and how big it is when collapsed.
///
/// On a notched MacBook we read the real notch out of `NSScreen`. On every other Mac we synthesise
/// one with the same dimensions a 14"/16" would have, so the app looks and behaves identically.
struct NotchGeometry: Equatable {
    /// Collapsed island size, in points. Matches the physical notch when there is one.
    var collapsedSize: CGSize
    /// Horizontal centre of the notch, in screen coordinates.
    var centerX: CGFloat
    /// Top edge of the screen, in screen coordinates (AppKit's bottom-left origin).
    var topY: CGFloat
    /// True when driven by real notch hardware rather than the synthetic fallback.
    var isPhysical: Bool

    /// Dimensions of the notch on a 14"/16" MacBook Pro at default scaling.
    ///
    /// ponytail: real notches vary by model and scaled resolution, so this is a starting point that
    /// Settings can override — not a constant to trust. See `Calibration`.
    static let syntheticSize = CGSize(width: 200, height: 32)

    /// User overrides for the synthetic notch, so a non-notch Mac can be dialled in by eye.
    struct Calibration: Equatable {
        var width: CGFloat?
        var height: CGFloat?
        static let none = Calibration(width: nil, height: nil)
    }

    static func detect(screen: NSScreen, calibration: Calibration = .none) -> NotchGeometry {
        let frame = screen.frame

        // A real notch shows up as a top safe-area inset with a gap between the two auxiliary areas.
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            return NotchGeometry(
                collapsedSize: CGSize(width: right.minX - left.maxX, height: screen.safeAreaInsets.top),
                centerX: (left.maxX + right.minX) / 2,
                topY: frame.maxY,
                isPhysical: true
            )
        }

        return NotchGeometry(
            collapsedSize: CGSize(
                width: calibration.width ?? syntheticSize.width,
                height: calibration.height ?? syntheticSize.height
            ),
            centerX: frame.midX,
            topY: frame.maxY,
            isPhysical: false
        )
    }
}
