//
//  LayoutGesture.swift
//  OpenSwiftUICore
//
//  Audited for 6.5.4
//  Status: WIP

// MARK: - LayoutGesture [WIP]

package protocol LayoutGesture: PrimitiveDebuggableGesture, PrimitiveGesture where Value == () {
    var responder: MultiViewResponder { get }

    func updateEventBindings(
        _ events: inout [EventID : any EventType],
        proxy: LayoutGestureChildProxy
    )
}

extension LayoutGesture {
    package static func _makeGesture(
        gesture: _GraphValue<Self>,
        inputs: _GestureInputs
    ) -> _GestureOutputs<Void> {
        // A LayoutGesture (e.g. DefaultLayoutGesture, the base responder's gesture for a plain
        // layout subview) carries no gesture-phase behavior — Value == () and updateEventBindings
        // is empty; its real work is responder/event routing, not phase computation. So the
        // faithful output is the inputs' default gesture outputs (a DefaultRule phase + the
        // indirect preference outputs). The caller (DefaultLayoutViewResponder.makeGesture) then
        // overrides its own default phase with this. The richer event-binding machinery
        // (LayoutGestureChildProxy / updateEventBindings) stays WIP upstream.
        inputs.makeDefaultOutputs()
    }

    package func updateEventBindings(
        _ events: inout [EventID : any EventType],
        proxy: LayoutGestureChildProxy
    ) {
        _openSwiftUIEmptyStub()
    }
}

// MARK: - DefaultLayoutGesture [WIP]

package struct DefaultLayoutGesture: LayoutGesture {
    package var responder: MultiViewResponder

    package typealias Body = Never
    package typealias Value = ()
}

// MARK: - LayoutGestureChildProxy [WIP]

package struct LayoutGestureChildProxy: RandomAccessCollection {
    package struct Child {
        package func binds(_ binding: EventBinding) -> Bool {
            _openSwiftUIUnimplementedFailure()
        }

        package func containsGlobalLocation(_ p: PlatformPoint) -> Bool {
            _openSwiftUIUnimplementedFailure()
        }
    }

    package var startIndex: Int {
        get { _openSwiftUIUnimplementedFailure() }
    }

    package var endIndex: Int {
        get { _openSwiftUIUnimplementedFailure() }
    }

    package subscript(index: Int) -> LayoutGestureChildProxy.Child {
        get { _openSwiftUIUnimplementedFailure() }
    }

    package func bindChild(
        index: Int,
        event: any EventType,
        id: EventID
    ) -> (from: EventBinding?, to: EventBinding?)? {
        _openSwiftUIUnimplementedFailure()
    }
}
