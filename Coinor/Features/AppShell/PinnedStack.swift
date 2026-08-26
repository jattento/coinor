import SwiftUI

/// A `ZStack` that always reports exactly the space its parent offered.
///
/// `ZStack { … }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()`
/// looks like it does this and does not. A flexible frame reports whatever
/// its child returns whenever the child returns *more* than was proposed, and
/// `.clipped()` only trims drawing, never layout. So a single oversized child
/// grows the stack, then the pane, then the detail column, until the window's
/// content is wider than the window itself and the hosting view centres the
/// overflow — which is what pushed the sidebar off the left window edge and
/// the terminal past the right one.
///
/// Here every child is proposed exactly the offered size and the stack
/// reports exactly the offered size. A child that still insists on more is
/// centred, as `ZStack` would, and stays contained in this stack alone.
struct PinnedStack: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let offered = ProposedViewSize(
            width: bounds.width,
            height: bounds.height
        )
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        for subview in subviews {
            subview.place(at: centre, anchor: .center, proposal: offered)
        }
    }
}
