import SwiftUI

/// SF Symbol animations are macOS 14+, and the deployment floor is 13.0 so that Macs older than the
/// notch — the whole "works on every Mac" claim — are actually included.
///
/// Everything here degrades to the plain symbol. The flourish is decoration; losing it on macOS 13
/// costs nothing functional, whereas excluding those Macs costs the positioning.
extension View {
    /// Cross-fades between two symbols instead of hard-cutting.
    @ViewBuilder
    func symbolReplaceTransition() -> some View {
        if #available(macOS 14.0, *) {
            contentTransition(.symbolEffect(.replace))
        } else {
            self
        }
    }

    /// Repeating pulse while `active`.
    @ViewBuilder
    func pulsingSymbol(_ active: Bool) -> some View {
        if #available(macOS 14.0, *) {
            symbolEffect(.pulse, options: .repeating, isActive: active)
        } else {
            self
        }
    }
}
