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

    private var eventBindings: [EventID: EventBinding] = [:]

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
        let from = eventBindings[identifier]
        guard let newResponder else {
            eventBindings[identifier] = nil
            return (from, nil)
        }
        let to = EventBinding(responder: newResponder)
        eventBindings[identifier] = to
        return (from, to)
    }

    package func willRemoveResponder(_ from: ResponderNode) {
        // [wandr] Drop any bindings pointing at a responder being torn down so we never
        // forward into a dead responder. Safe no-op if none match.
        eventBindings = eventBindings.filter { $0.value.responder !== from }
    }

    package func setInheritedPhase(_ phase: _GestureInputs.InheritedPhase) {
        host?.setInheritedPhase(phase)
    }

    private func sendDownstream(_ events: [EventID: any EventType]) -> Set<EventID> {
        guard let rootResponder, let host else {
            return []
        }
        isActive = true

        // 1. Bind each event to a responder (reusing an existing binding for its id),
        //    stamp the binding onto the event, and bucket by bound responder.
        var handled: Set<EventID> = []
        var boundByResponder: [ObjectIdentifier: (node: ResponderNode, events: [EventID: any EventType])] = [:]
        var time: Time = .zero

        for (id, rawEvent) in events {
            let binding: EventBinding
            if let existing = eventBindings[id] {
                binding = existing
            } else if let responder = bindResponder(for: rawEvent, root: rootResponder) {
                binding = EventBinding(responder: responder)
                eventBindings[id] = binding
                delegate?.didBind(to: binding, id: id)
            } else {
                continue
            }

            var event = rawEvent
            event.binding = binding
            if time < event.timestamp {
                time = event.timestamp
            }

            let key = ObjectIdentifier(binding.responder)
            if var bucket = boundByResponder[key] {
                bucket.events[id] = event
                boundByResponder[key] = bucket
            } else {
                boundByResponder[key] = (binding.responder, [id: event])
            }
            handled.insert(id)
        }

        guard !boundByResponder.isEmpty else {
            return []
        }

        // 2. Forward each bucket to the host, which routes to the responder's gesture
        //    graph, then report the resulting phase back to the delegate (terminal →
        //    the host resets the bindings for the next sequence).
        for (_, bucket) in boundByResponder {
            let phase = host.sendEvents(bucket.events, rootNode: bucket.node, at: time)
            delegate?.didUpdate(phase: phase, in: self)
        }
        return handled
    }

    /// [wandr] Resolve an event to the responder that should receive it.
    ///
    /// First tries the structural `bindEvent` traversal. With `GestureContainerFeature`
    /// disabled (no geometric hit-testing leaf responders exist yet), that returns nil
    /// for a gesture whose content produced no responders, so we fall back to a
    /// structural search for the first valid gesture responder. This delivers a single
    /// `.onTapGesture` regardless of the precise hit location — correct enough for the
    /// first milestone; true geometry is a follow-up (see HitTestBindingModifier).
    private func bindResponder(for event: any EventType, root: ResponderNode) -> ResponderNode? {
        if let bound = root.bindEvent(event) {
            return bound
        }
        // [wandr] With geometric hit-testing on, root.bindEvent already did a location-aware
        // hit-test; a nil result means the point hit no gesture's content, so we must NOT fall
        // back to "first valid gesture regardless of location" (that's the old location-blind
        // behavior). Only use the structural fallback when the geometric path is disabled.
        guard !GestureContainerFeature.isEnabled else {
            return nil
        }
        guard HitTestableEvent(event) != nil else {
            return nil
        }
        var found: ResponderNode?
        root.visit { node in
            if let gesture = node as? any AnyGestureResponder {
                // Materialize the gesture container; a GestureResponder only reports
                // `isValid == true` once its container exists (it is created lazily, and
                // nothing on the structural path would otherwise trigger it).
                _ = gesture.gestureContainer
                if gesture.isValid {
                    found = node
                    return .cancel
                }
            }
            return .next
        }
        return found
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
