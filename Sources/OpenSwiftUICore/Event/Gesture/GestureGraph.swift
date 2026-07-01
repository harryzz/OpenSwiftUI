//
//  GestureGraph.swift
//  OpenSwiftUICore
//
//  Audited for 6.5.4
//  Status: WIP

import OpenAttributeGraphShims

// MARK: - GestureGraphDelegate

package protocol GestureGraphDelegate: AnyObject {
    func enqueueAction(_ action: @escaping () -> Void)
}

// MARK: - GestureGraph [WIP]

final package class GestureGraph: GraphHost, EventGraphHost, CustomStringConvertible {
    weak var rootResponder: AnyGestureResponder?
    weak var delegate: GestureGraphDelegate?
    package let eventBindingManager: EventBindingManager
    @Attribute private var gestureTime: Time
    @Attribute private var gestureEvents: [EventID: any EventType]
    @Attribute private var inheritedPhase: _GestureInputs.InheritedPhase
    @Attribute private var gestureResetSeed: UInt32
    @OptionalAttribute private var rootPhase: GesturePhase<()>?
    @OptionalAttribute private var gestureDebug: GestureDebug.Data?
    @OptionalAttribute private var gestureCategoryAttr: GestureCategory?
    @OptionalAttribute private var gestureLabelAttr: String??
    @OptionalAttribute private var isCancellableAttr: Bool?
    @OptionalAttribute private var requiredTapCountAttr: Int??
    @OptionalAttribute private var gestureDependencyAttr: GestureDependency?
    @Attribute private var gesturePreferenceKeys: PreferenceKeys
    var nextUpdateTime: Time
    // [wandr] Set when a sequence ended terminal; consumed (reset seed bumped) at the START of the
    // next sequence so re-arming happens in the same transaction as the new sequence's first event.
    var lastPhaseWasTerminal: Bool = false

    init(rootResponder: AnyGestureResponder) {
        self.rootResponder = rootResponder
        let manager = EventBindingManager()
        self.eventBindingManager = manager
        // [wandr] Mirror ViewGraph.init: pin the new graph's globalSubgraph as current so
        // the inherited @Attribute storage is created inside this host's graph.
        let data = GraphHost.Data()
        Subgraph.current = data.globalSubgraph
        _gestureTime = Attribute(value: .zero)
        _gestureEvents = Attribute(value: [:])
        _inheritedPhase = Attribute(value: .defaultValue)
        _gestureResetSeed = Attribute(value: .zero)
        _gesturePreferenceKeys = Attribute(value: .init())
        nextUpdateTime = .infinity
        super.init(data: data)
        Subgraph.current = nil
        manager.host = self
    }

    package var description: String {
        "GestureGraph<\(rootResponder.map { String(describing: $0.gestureType) } ?? "nil")> \(self)"
    }

    override package func instantiateOutputs() {
        guard let rootResponder else {
            return
        }
        // [wandr] Force the EventBindingBridge into existence. GestureResponder creates
        // it lazily and, in doing so, sets `self.delegate = bridge`. The delegate is what
        // `enqueueAction` (and therefore CallbacksPhase's gesture-action dispatch via
        // `GestureGraph.current.enqueueAction`) routes through. Without this, tap actions
        // would be silently dropped.
        _ = rootResponder.eventSources
        let outputs: _GestureOutputs<Void> = rootSubgraph.apply {
            var inputs = _GestureInputs(
                rootResponder.inputs,
                viewSubgraph: rootResponder.viewSubgraph,
                events: $gestureEvents,
                time: $gestureTime,
                resetSeed: $gestureResetSeed,
                inheritedPhase: $inheritedPhase,
                gesturePreferenceKeys: $gesturePreferenceKeys
            )
            // `.gestureGraph` makes the gesture's phase logic build inside THIS graph
            // (view inputs still resolve in the ViewGraph via an indirect child subgraph),
            // and routes CallbacksPhase actions through this graph's delegate.
            inputs.options.insert(.gestureGraph)
            return rootResponder.makeGesture(inputs: inputs)
        }
        $rootPhase = outputs.phase
    }

    override package func uninstantiateOutputs() {
        $rootPhase = nil
        _ = gestureEvents
        gestureEvents = [:]
        inheritedPhase = .failed
        gestureResetSeed = .zero
        gesturePreferenceKeys = .init()
        if let rootResponder {
            rootResponder.resetGesture()
        }
    }

    override package func timeDidChange() {
        nextUpdateTime = .infinity
    }

    package var responderNode: ResponderNode? {
        rootResponder
    }

    package var focusedResponder: ResponderNode? {
        guard let rootResponder,
              let host = rootResponder.host,
              let eventGraphHost = host.as(EventGraphHost.self) else {
            return nil
        }
        return eventGraphHost.focusedResponder
    }

    package var nextGestureUpdateTime: Time {
        nextUpdateTime
    }

    package func setInheritedPhase(_ phase: _GestureInputs.InheritedPhase) {
        inheritedPhase = phase
    }

    package func sendEvents(
        _ events: [EventID: any EventType],
        rootNode: ResponderNode,
        at time: Time
    ) -> GesturePhase<Void> {
        guard let rootResponder, rootResponder.isValid else {
            return .failed
        }
        return Update.perform {
            instantiateIfNeeded()
            guard isInstantiated else {
                return .failed
            }
            // [wandr] Re-arm for a new sequence at its START (not after the previous terminal):
            // if the previous sequence ended terminal, bump the reset seed NOW — before processing
            // this sequence's events in the SAME transaction — so the gesture rules reset and the
            // fresh down/up fires cleanly. Bumping AFTER the terminal raced with the next down
            // arriving before the bump propagated, causing intermittent first-attempt misses on
            // device (NO subgraph teardown — the bump is the only re-arm).
            if lastPhaseWasTerminal {
                gestureResetSeed &+= 1
                lastPhaseWasTerminal = false
            }
            gestureTime = time
            gestureEvents = events
            // Drive a transactional update so the (transactional) CallbacksPhase runs and
            // enqueues the gesture action, then read back the resolved root phase.
            runTransaction()
            let phase = rootPhase ?? .failed
            if phase.isTerminal {
                lastPhaseWasTerminal = true
            }
            return phase
        }
    }

    package func resetEvents() {
        uninstantiate(immediately: false)
    }

    package func enqueueAction(_ action: @escaping () -> Void) {
        delegate?.enqueueAction(action)
    }

    @inline(__always)
    func access<T>(_ body: @autoclosure () -> T) -> T {
        Update.perform {
            instantiateIfNeeded()
            return body()
        }
    }

    package func gestureCategory() -> GestureCategory? {
        guard let rootResponder, rootResponder.isValid else {
            return nil
        }
        return access(gestureCategoryAttr)
    }

    @inline(__always)
    var gestureLabel: String? {
        guard isInstantiated else {
            return nil
        }
        return Update.perform {
            gestureLabelAttr ?? nil
        }
    }

    @inline(__always)
    var isCancellable: Bool {
        access(isCancellableAttr ?? false)
    }

    @inline(__always)
    var requiredTapCount: Int? {
        access(requiredTapCountAttr ?? nil)
    }

    @inline(__always)
    var gestureDependency: GestureDependency {
        access(gestureDependencyAttr ?? .none)
    }
}

extension GestureGraph {
    package static var current: GestureGraph {
        GraphHost.currentHost as! GestureGraph
    }
}
