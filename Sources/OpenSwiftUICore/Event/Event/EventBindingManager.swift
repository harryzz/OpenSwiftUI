//
//  EventBindingManager.swift
//  OpenSwiftUICore
//
//  Status: WIP
//  ID: D63F4C292364B83D9F441CFC1A31B3F3 (SwiftUICore)

import Foundation
// MARK: - EventBindingManager [6.5.4] [WIP]

@_spi(ForOpenSwiftUIOnly)
@available(OpenSwiftUI_v6_0, *)
final public class EventBindingManager {
    package weak var host: (any EventGraphHost)?

    package weak var delegate: (any EventBindingManagerDelegate)?

    private var forwardedEventDispatchers: [ObjectIdentifier: any ForwardedEventDispatcher] = [:]

    // [wandr] An event id may bind to MORE THAN ONE gesture responder simultaneously — the
    // most-specific gesture overall PLUS the most-specific tap — so a click and a drag over the
    // same region are both offered the event and each self-selects (a tap needs stillness, a drag
    // needs movement). See `bindResponders`.
    private var eventBindings: [EventID: [EventBinding]] = [:]

    private(set) package var isActive: Bool = false

    package static var current: EventBindingManager? {
        guard let delegate = ViewGraph.current.delegate,
              let host = delegate as? ViewRendererHost,
              let eventGraphHost = host.as(EventGraphHost.self)
        else {
            return nil
        }
        return eventGraphHost.eventBindingManager
    }

    private var eventTimer: Timer?

    package init() {
        _openSwiftUIEmptyStub()
    }

    deinit {
        eventTimer?.invalidate()
    }

    package func addForwardedEventDispatcher(_ dispatcher: any ForwardedEventDispatcher) {
        forwardedEventDispatchers[ObjectIdentifier(type(of: dispatcher).eventType)] = dispatcher
    }

    package func rebindEvent(
        _ identifier: EventID,
        to newResponder: ResponderNode?
    ) -> (from: EventBinding?, to: EventBinding?)? {
        // [wandr] Minimal: drop/replace the stored binding for this id. Not on the basic
        // tap path (used by gestures that re-target mid-sequence); kept safe + trap-free.
        let from = eventBindings[identifier]?.first
        guard let newResponder else {
            eventBindings[identifier] = nil
            return (from, nil)
        }
        let to = EventBinding(responder: newResponder)
        eventBindings[identifier] = [to]
        return (from, to)
    }

    package func willRemoveResponder(_ from: ResponderNode) {
        // [wandr] Drop any bindings pointing at a responder being torn down so we never
        // forward into a dead responder. Safe no-op if none match.
        eventBindings = eventBindings.compactMapValues { bindings in
            let kept = bindings.filter { $0.responder !== from }
            return kept.isEmpty ? nil : kept
        }
    }

    package func setInheritedPhase(_ phase: _GestureInputs.InheritedPhase) {
        host?.setInheritedPhase(phase)
    }

    private func sendDownstream(_ events: [EventID: any EventType]) -> Set<EventID> {
        guard let rootResponder, let host else {
            return []
        }
        isActive = true

        // 1. Bind each event to its responder(s) (reusing existing bindings for its id), stamp the
        //    matching binding onto a copy of the event per responder, and bucket by bound responder.
        var handled: Set<EventID> = []
        var boundByResponder: [ObjectIdentifier: (node: ResponderNode, events: [EventID: any EventType])] = [:]
        var time: Time = .zero

        for (id, rawEvent) in events {
            let bindings: [EventBinding]
            if let existing = eventBindings[id] {
                bindings = existing
            } else {
                let responders = bindResponders(for: rawEvent, root: rootResponder)
                guard !responders.isEmpty else {
                    continue
                }
                bindings = responders.map { EventBinding(responder: $0) }
                eventBindings[id] = bindings
                for binding in bindings {
                    delegate?.didBind(to: binding, id: id)
                }
            }

            if time < rawEvent.timestamp {
                time = rawEvent.timestamp
            }
            // Deliver to every bound responder — each receives the event stamped with its own
            // binding, so the gesture graph routes it correctly.
            for binding in bindings {
                var event = rawEvent
                event.binding = binding
                let key = ObjectIdentifier(binding.responder)
                if var bucket = boundByResponder[key] {
                    bucket.events[id] = event
                    boundByResponder[key] = bucket
                } else {
                    boundByResponder[key] = (binding.responder, [id: event])
                }
            }
            handled.insert(id)
        }

        guard !boundByResponder.isEmpty else {
            return []
        }

        // 2. Forward each bucket to the host, which routes to the responder's gesture graph, then
        //    report each phase back to the delegate (terminal → the host resets bindings for the next
        //    sequence). When an event is co-delivered to a tap AND a drag over the same region,
        //    process the DISCRETE (tap) responder FIRST so the tap fires before the drag's terminal
        //    reset can invalidate it. The per-bucket `didUpdate` (→ reset) MUST run between buckets —
        //    deferring it and calling the next `sendEvents` first re-enters the guest component.
        let orderedBuckets = boundByResponder.values.sorted { a, b in
            let aTap = (a.node as? any AnyGestureResponder)?.producesVoidValue ?? false
            let bTap = (b.node as? any AnyGestureResponder)?.producesVoidValue ?? false
            return aTap && !bTap
        }
        var terminated: Set<ObjectIdentifier> = []
        for bucket in orderedBuckets {
            let phase = host.sendEvents(bucket.events, rootNode: bucket.node, at: time)
            delegate?.didUpdate(phase: phase, in: self)
            if phase.isTerminal {
                terminated.insert(ObjectIdentifier(bucket.node))
            }
        }
        // [wandr] Remove ONLY the bindings whose gesture reached a terminal phase — never blanket-
        // clear the sequence. With co-delivery (a tap + a drag bound to one event), the tap FAILS
        // the instant the swipe moves; a blanket reset would then also drop the still-active drag's
        // binding, rebind it mid-gesture, and lose its onEnded → eleev's `ignoreGesture` stays true
        // and swipes freeze until it happens to recover. Granular removal keeps the drag alive to
        // its own terminal (up), so onEnded always fires.
        if !terminated.isEmpty {
            for id in handled {
                guard var bindings = eventBindings[id] else { continue }
                bindings.removeAll { terminated.contains(ObjectIdentifier($0.responder)) }
                eventBindings[id] = bindings.isEmpty ? nil : bindings
            }
            if eventBindings.isEmpty {
                isActive = false
            }
        }
        return handled
    }

    /// [wandr] Resolve an event to the responder that should receive it, by geometric specificity:
    /// among ALL valid gesture responders whose hit frame contains the point, bind the MOST SPECIFIC
    /// (smallest hit frame). This is the tightest interactive region under the pointer, so a button's
    /// tap (e.g. 48×48) wins over an overlapping broad drag (e.g. a full-screen side-menu swipe area
    /// drawn over the header buttons), and the board's DragGesture wins over the full-screen dismiss
    /// tap for a board swipe. `root.bindEvent`'s plain front-to-back traversal instead returned the
    /// frontmost *sibling* that merely contained the point, so a broad frontmost gesture swallowed
    /// every event meant for a tighter gesture beneath it.
    ///
    /// Returns an array for the caller's multi-binding shape, but binds exactly ONE responder:
    /// co-delivering a single event to two gesture graphs re-enters the guest component on the 2nd
    /// sequence and traps ("cannot enter component instance"). Consequence: dismissing an overlay by
    /// tapping its full-screen backdrop over a tighter drag region does NOT work — dismiss via the
    /// overlay's own controls. True simultaneous arbitration is a follow-up (needs the gesture graph
    /// to accept concurrent sequences without re-entrancy).
    ///
    /// Structural path (`GestureContainerFeature` disabled): fall back to the first valid gesture
    /// regardless of location — kept for the no-geometry configuration.
    private func bindResponders(for event: any EventType, root: ResponderNode) -> [ResponderNode] {
        guard GestureContainerFeature.isEnabled else {
            if let bound = root.bindEvent(event) {
                return [bound]
            }
            guard HitTestableEvent(event) != nil else {
                return []
            }
            var found: ResponderNode?
            root.visit { node in
                if let gesture = node as? any AnyGestureResponder {
                    _ = gesture.gestureContainer
                    if gesture.isValid {
                        found = node
                        return .cancel
                    }
                }
                return .next
            }
            return found.map { [$0] } ?? []
        }
        guard let hitEvent = HitTestableEvent(event) else {
            return []
        }
        let point = hitEvent.hitTestLocation
        var smallest: (node: ResponderNode, area: CGFloat, priority: Int)?
        var smallestTap: (node: ResponderNode, area: CGFloat)?
        root.visit { node in
            if let gesture = node as? any AnyGestureResponder {
                // Materialize the container; `isValid` is false until it exists (created lazily).
                _ = gesture.gestureContainer
                let frame = gesture.hitFrame
                // [wandr] `frame` is the gesture's LOCAL layout rect. Under an `.offset`/GeometryEffect
                // the descendant's layout `position` is reset to zero and the placement lives in
                // `viewTransform` instead — so map the global hit `point` into that local space before
                // testing containment. Use `.localToSpace(.global)` (NOT `.spaceToLocal`): the
                // GeometryEffect appends its effect with `inverse: true`, so `viewTransform` already
                // encodes the global→local orientation — this matches the canonical
                // `GeometryProxy.convert(globalPoint:to:)` (GeometryReader.swift). No-op for identity
                // transforms, so plain (un-transformed) gestures are unaffected.
                let localPoint = gesture.viewTransform.convert(.localToSpace(.global), point: point)
                // [wandr] Content-shape hit region: SwiftUI hit-tests where content is actually
                // DRAWN, not the full layout frame. Restrict `frame` to the content's drawn bounds
                // when known (e.g. a board centered in a greedy GeometryReader is hittable only over
                // the board, not the transparent padding). Fall back to `frame` when there is no
                // display content or the intersection is empty (defensive).
                let hitRegion: CGRect = {
                    guard let cb = gesture.contentBounds else { return frame }
                    let r = frame.intersection(cb)
                    return (r.isNull || r.isEmpty) ? frame : r
                }()
                // Skip gestures whose subtree has `.allowsHitTesting(false)` (an open overlay
                // disabling the background it covers) so they don't intercept events.
                if gesture.isValid, gesture.hitTestable, hitRegion.contains(localPoint) {
                    let area = hitRegion.width * hitRegion.height
                    // [wandr] Gesture PRIORITY is the primary key; area is the tie-break among equal
                    // priority. `.highPriorityGesture` (exclusionPolicy `.highPriority`) therefore wins
                    // over lower-priority overlapping gestures REGARDLESS of area — that's the point of
                    // high priority, and it's how a scroll pan beats an ANCESTOR `.gesture` that wraps it
                    // even when the ancestor's DRAWN hit region is smaller. (Ancestor/descendant depth
                    // can't decide it here: the responder tree is flat — parent/nextResponder is never
                    // wired.) With every gesture at `.default` the priority test is a no-op and the old
                    // tightest-region behavior is byte-identical. `smallestTap` below stays purely
                    // area-based, so a TAP still binds the tightest button/toggle and is co-delivered
                    // alongside the scroll — a tap toggles, a drag scrolls (each self-arbitrates by
                    // movement).
                    let priority = (gesture.exclusionPolicy == .highPriority) ? 1 : 0
                    if smallest == nil
                        || priority > smallest!.priority
                        || (priority == smallest!.priority && area < smallest!.area) {
                        smallest = (node, area, priority)
                    }
                    if gesture.producesVoidValue, smallestTap == nil || area < smallestTap!.area {
                        smallestTap = (node, area)
                    }
                }
            }
            return .next
        }
        // Deliver to the most-specific gesture overall PLUS the most-specific TAP (when different),
        // so a click self-selects the tap even where a tighter continuous (drag) region overlaps —
        // e.g. tapping the board area to dismiss an open overlay while the board's own DragGesture is
        // the smallest gesture there. Both self-arbitrate by movement (tap = stillness, drag =
        // translation), so co-delivering is safe; a broader same-kind gesture is deliberately NOT
        // bound, so it can't steal the event or double-fire.
        var result: [ResponderNode] = []
        if let smallest {
            result.append(smallest.node)
        }
        if let smallestTap, smallestTap.node !== smallest?.node {
            result.append(smallestTap.node)
        }
        return result
    }

    @discardableResult
    package func send(_ events: [EventID: any EventType]) -> Set<EventID> {
        Update.locked { [weak self] in
            guard let self else {
                return []
            }
            return sendDownstream(events)
        }
    }

    package func send<E>(_ event: E, id: Int) where E: EventType {
        send([EventID(type: E.self, serial: id): event])
    }

    package var rootResponder: ResponderNode? {
        host?.responderNode
    }

    package var focusedResponder: ResponderNode? {
        // [wandr] No keyboard/focus responder routing yet. Returning nil directly (rather
        // than delegating to the host, which would recurse back here) keeps the tap path
        // simple and avoids a focus subsystem we have not built.
        nil
    }

    package func reset(resetForwardedEventDispatchers: Bool = false) {
        // [wandr] Drop bindings so the next pointer-down rebinds fresh. We intentionally
        // do NOT tear down gesture subgraphs here (Subgraph.forEach swiftcall mislowering
        // on wasm32-wasip1) — GestureGraph.sendEvents bumps its reset seed in-graph to
        // re-arm the gesture for the next sequence.
        eventBindings.removeAll()
        if resetForwardedEventDispatchers {
            for key in forwardedEventDispatchers.keys {
                forwardedEventDispatchers[key]?.reset()
            }
        }
        isActive = false
    }

    package func isActive<E>(for eventType: E.Type) -> Bool where E: EventType {
        guard isActive else {
            return false
        }
        return eventBindings.contains { ObjectIdentifier($0.key.type) == ObjectIdentifier(E.self) }
    }

    package func binds<E>(_ event: E) -> Bool where E: EventType {
        rootResponder?.bindEvent(event) != nil
    }
}

@_spi(ForOpenSwiftUIOnly)
@available(*, unavailable)
extension EventBindingManager: Sendable {}

// MARK: - ForwardedEventDispatcher [6.5.4]

package protocol ForwardedEventDispatcher {
    static var eventType: any EventType.Type { get }

    var isActive: Bool { get }

    func wantsEvent(
        _ event: any EventType,
        manager: EventBindingManager
    ) -> Bool

    mutating func receiveEvents(
        _ events: [EventID: any EventType],
        manager: EventBindingManager
    ) -> Set<EventID>

    mutating func reset()
}

extension ForwardedEventDispatcher {
    package var isActive: Bool { false }

    package func wantsEvent(
        _ event: any EventType,
        manager: EventBindingManager
    ) -> Bool {
        true
    }

    package mutating func reset() {}
}

// MARK: - EventBindingManagerDelegate [6.5.4]

package protocol EventBindingManagerDelegate: AnyObject {
    func didBind(
        to newBinding: EventBinding,
        id: EventID
    )

    func didUpdate(
        phase: GesturePhase<Void>,
        in eventBindingManager: EventBindingManager
    )

    func didUpdate(
        gestureCategory: GestureCategory,
        in eventBindingManager: EventBindingManager
    )
}

extension EventBindingManagerDelegate {
    package func didBind(
        to newBinding: EventBinding,
        id: EventID
    ) {
        _openSwiftUIEmptyStub()
    }

    package func didUpdate(
        gestureCategory: GestureCategory,
        in eventBindingManager: EventBindingManager
    ) {
        _openSwiftUIEmptyStub()
    }
}
