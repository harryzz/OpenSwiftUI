//
//  ScrollView.swift
//  OpenSwiftUICore
//
//  [wandr] A real, off-Apple ScrollView.
//
//  Upstream OpenSwiftUI left ScrollView unimplemented — this directory holds only WIP scaffolding
//  (the `Scrollable` marker protocol, `ScrollPosition`, `ScrollGeometry`, `ScrollTarget`), and the
//  `ScrollView` view itself existed nowhere but doc-comment examples. Rather than an apple-compat
//  shim, this is a genuine OpenSwiftUI view in the correct place, composed from OpenSwiftUI's own
//  primitives: a custom `Layout` measures the content's ideal height (so we don't need
//  `onPreferenceChange`, which isn't implemented on this platform) and places it at a drag-driven
//  offset, clipped to the viewport. Vertical only for now — the axis the eleev/2048 Settings list
//  needs; horizontal + scroll indicators + the full `Scrollable`/`ScrollPosition` graph integration
//  are follow-ups.
//
//  TODO: fold the apple-compat shim's `List` into OpenSwiftUI the same way (a real view here),
//  backed by this ScrollView, once its section/style/selection surface is covered.

import Foundation
// Shared measurement between the scroll `Layout` (which knows the content + viewport heights) and the
// drag gesture (which needs the resulting max offset to clamp the committed scroll). A reference type
// so both see the same value — the platform has no `onPreferenceChange` to bubble it up via @State.
private final class ScrollMetrics {
    var maxOffset: CGFloat = 0
}

/// A scrollable view.
///
/// The scroll view displays its content within the scrollable content region. As the user performs
/// platform-appropriate scroll gestures, the scroll view adjusts what portion of the underlying
/// content is visible.
public struct ScrollView<Content>: View where Content: View {

    /// The scroll view's content.
    public var content: Content

    /// The scrollable axes of the scroll view. (Only `.vertical` is honored for now.)
    public var axes: Axis.Set

    @State private var offset: CGFloat = 0            // committed scroll distance (>= 0, downward)
    @State private var live: CGFloat = 0             // in-flight drag translation (points)
    @State private var metrics = ScrollMetrics()

    /// Creates a new instance that's scrollable in the direction of the given axis and can show
    /// indicators while scrolling.
    public init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true, @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.content = content()
    }

    public var body: some View {
        // Content Y offset = liveTranslation - committedScroll. Dragging up (negative translation)
        // moves content up, revealing lower content; the Layout clamps for display and records the
        // valid range in `metrics` so `onEnded` can clamp the committed value too.
        ScrollContentLayout(displayOffset: live - offset, metrics: metrics) {
            content
        }
        // Full-viewport hit region: hit-testing is content-shape-based, so without a drawn background
        // the scroll gesture only covers the drawn rows and a drag on a transparent gap falls through
        // to the ancestor gesture. An always-drawn clear background fills the scroll gesture's content
        // bounds to the whole viewport → the scroll gesture is a candidate everywhere in its area.
        .background { Color.clear }
        .clipped()
        // High-priority so the scroll pan wins arbitration over an ANCESTOR `.gesture` that wraps the
        // scroll view (e.g. a swipe-to-move gesture on a container that also hosts this list). In this
        // port the responder tree is flat (gesture nesting isn't preserved), so ancestor/descendant
        // depth can't decide it; `.highPriorityGesture` marks this responder's exclusionPolicy, which
        // EventBindingManager.bindResponders uses to break the equal-area tie in the scroll's favor.
        .highPriorityGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in live = value.translation.height }
                .onEnded { value in
                    offset = min(max(offset - value.translation.height, 0), metrics.maxOffset)
                    live = 0
                }
        )
    }
}

/// Lays a single content subview out at a vertical offset, sized to its own ideal height, within the
/// scroll view's (viewport-sized) bounds. The enclosing `.clipped()` hides the overflow.
private struct ScrollContentLayout: Layout {
    var displayOffset: CGFloat
    let metrics: ScrollMetrics

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout Void) -> CGSize {
        // The scroll view fills the space it's offered (the viewport); it does not grow to content.
        CGSize(width: proposal.width ?? .zero, height: proposal.height ?? .zero)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout Void) {
        guard let content = subviews.first else { return }
        // Measure the content's ideal height at the viewport width (height unconstrained).
        let contentHeight = content.dimensions(in: ProposedViewSize(width: bounds.width, height: nil)).height
        let maxOffset = max(0, contentHeight - bounds.height)
        metrics.maxOffset = maxOffset
        // Clamp the display offset to [-maxOffset, 0]: 0 = top, -maxOffset = bottom, no overscroll.
        let y = min(max(displayOffset, -maxOffset), 0)
        content.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + y),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: contentHeight)
        )
    }
}
