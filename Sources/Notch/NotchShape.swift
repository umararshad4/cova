import SwiftUI

/// The notch/island outline: square at the top where it meets the screen edge, rounded at the
/// bottom, with concave fillets flowing outward into the menu bar.
struct NotchShape: Shape {
    /// Radius of the outward-flowing concave corners at the top.
    var topRadius: CGFloat
    /// Radius of the rounded bottom corners.
    var bottomRadius: CGFloat

    /// Lets SwiftUI interpolate the corner radii during expand/collapse instead of snapping.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { (topRadius, bottomRadius) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Radii can't exceed what the box can hold, or the arcs cross over and the path inverts.
        let bottom = min(bottomRadius, rect.height, rect.width / 2)
        let top = min(topRadius, max(0, rect.height - bottom))

        p.move(to: CGPoint(x: rect.minX - top, y: rect.minY))
        p.addArc(
            center: CGPoint(x: rect.minX - top, y: rect.minY + top),
            radius: top, startAngle: .degrees(-90), endAngle: .zero, clockwise: false
        )
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottom))
        p.addArc(
            center: CGPoint(x: rect.minX + bottom, y: rect.maxY - bottom),
            radius: bottom, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true
        )
        p.addLine(to: CGPoint(x: rect.maxX - bottom, y: rect.maxY))
        p.addArc(
            center: CGPoint(x: rect.maxX - bottom, y: rect.maxY - bottom),
            radius: bottom, startAngle: .degrees(90), endAngle: .zero, clockwise: true
        )
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + top))
        p.addArc(
            center: CGPoint(x: rect.maxX + top, y: rect.minY + top),
            radius: top, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false
        )
        p.closeSubpath()
        return p
    }
}
