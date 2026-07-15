//
//  GestureViewModifier.swift
//  OpenSwiftUICore
//
//  Audited for 6.5.4
//  Status: Complete
//  ID: 9DF46B4E935FF03A55FF3DDFB0B1FF2B (SwiftUICore)

package import Foundation
package import OpenAttributeGraphShims

// MARK: - GestureViewModifier

package protocol GestureViewModifier: MultiViewModifier, PrimitiveViewModifier {
    associatedtype ContentGesture: Gesture
    
    associatedtype Combiner: GestureCombiner = DefaultGestureCombiner
    
    var gesture: ContentGesture { get }
    
    var name: String? { get }
    
    var gestureMask: GestureMask { get }
}

// MARK: - GestureResponderExclusionPolicy

@_spi(ForOpenSwiftUIOnly)
@available(OpenSwiftUI_v6_0, *)
public enum GestureResponderExclusionPolicy {
    case `default`
    
    case highPriority
    
    case simultaneous
}

@_spi(ForOpenSwiftUIOnly)
@available(*, unavailable)
extension GestureResponderExclusionPolicy: Sendable {}

// MARK: - GestureCombiner

package protocol GestureCombiner {
    associatedtype Result: Gesture where Result.Value == ()

    static func combine(
        _ gesture1: AnyGesture<Void>,
        _ gesture2: AnyGesture<Void>
    ) -> Result

    static var exclusionPolicy: GestureResponderExclusionPolicy { get }
}

// MARK: - GestureViewModifier + Default Implementation

extension GestureViewModifier {
    package var name: String? { nil }
    
    package var gestureMask: GestureMask { .all }
    
    package static func makeView(
        modifier: _GraphValue<Self>,
        inputs: _ViewInputs,
        body: @escaping (_Graph, _ViewInputs) -> _ViewOutputs
    ) -> _ViewOutputs {
        var outputs = body(_Graph(), inputs)
        if inputs.preferences.requiresViewResponders {
            let filter = GestureFilter(
                children: outputs.viewResponders(),
                modifier: modifier.value,
                position: inputs.animatedPosition(),
                size: inputs.animatedCGSize(),
                hitTestable: inputs.allowsHitTesting,
                transform: inputs.transform,
                contentDisplayList: OptionalAttribute(outputs.preferences.displayList),
                inputs: inputs,
                viewSubgraph: .current!
            )
            outputs.preferences.viewResponders = Attribute(filter)
        }
        let provider = inputs.gestureAccessibilityProvider
        provider.makeGesture(
            mask: modifier.value[keyPath: \.gestureMask],
            inputs: inputs,
            outputs: &outputs
        )
        return outputs
    }
    
    package static func _makeView(
        modifier: _GraphValue<Self>,
        inputs: _ViewInputs,
        body: @escaping (_Graph, _ViewInputs) -> _ViewOutputs
    ) -> _ViewOutputs {
        makeView(modifier: modifier, inputs: inputs, body: body)
    }
}

// MARK: - AddGestureModifier

package struct AddGestureModifier<T>: GestureViewModifier where T: Gesture {
    package var gesture: T
    package var name: String?
    package var gestureMask: GestureMask
    
    package init(
        _ gesture: T,
        name: String? = nil,
        gestureMask: GestureMask = .all
    ) {
        self.gesture = gesture
        self.name = name
        self.gestureMask = gestureMask
    }
    
    package typealias Combiner = DefaultGestureCombiner

    package typealias ContentGesture = T
}

// MARK: - DefaultGestureCombiner

package struct DefaultGestureCombiner: GestureCombiner {
    package typealias Base = ExclusiveGesture<AnyGesture<Void>, AnyGesture<Void>>

    package typealias Result = _MapGesture<DefaultGestureCombiner.Base, Void>

    package static var exclusionPolicy: GestureResponderExclusionPolicy { .default }

    package static func combine(
        _ first: AnyGesture<Void>,
        _ second: AnyGesture<Void>
    ) -> DefaultGestureCombiner.Result {
        first.exclusively(before: second).map { _ in }
    }
}

// MARK: - AnyGestureContainingResponder

package protocol AnyGestureContainingResponder: ViewResponder {
    var viewSubgraph: Subgraph { get }

    var eventSources: [any EventBindingSource] { get }

    var gestureType: any Any.Type { get }

    var isValid: Bool { get }

    func detachContainer()
}

// MARK: - AnyGestureResponder

package protocol AnyGestureResponder: AnyGestureContainingResponder {
    var inputs: _ViewInputs { get }

    // [wandr] The gesture's global hit frame (its modified view's layout frame). Used by
    // EventBindingManager to bind the MOST SPECIFIC (smallest-area) gesture under the pointer.
    var hitFrame: CGRect { get }

    // [wandr] True when the gesture carries no continuous value (Value == Void, e.g. TapGesture) —
    // i.e. a DISCRETE gesture; a continuous gesture (DragGesture) has a non-Void Value. Lets
    // EventBindingManager also bind the most-specific TAP under the pointer, so a click is
    // recognized even where a tighter continuous (drag) region overlaps it (e.g. tap-to-dismiss an
    // overlay while the board's DragGesture is the tightest gesture there).
    var producesVoidValue: Bool { get }

    // [wandr] False when `.allowsHitTesting(false)` covers this gesture's subtree — bindResponders
    // then skips it, so an open overlay's background stops intercepting events.
    var hitTestable: Bool { get }

    // [wandr] The transform mapping this gesture's LOCAL space (in which `hitFrame` is expressed)
    // to global. `.offset`/`.scaleEffect`/etc. are GeometryEffects that reset the descendant's
    // layout `position` to zero and carry the placement here instead — so `hitFrame` alone is the
    // un-offset local rect. bindResponders inverse-maps the global hit point through this before
    // testing `hitFrame.contains`.
    var viewTransform: ViewTransform { get }

    // [wandr] Content-shape hit region (drawn DisplayList bounds), in the same local space as
    // `hitFrame`. When present, hit-testing uses this ∩ `hitFrame` so the gesture only fires over
    // actually-drawn content (matching SwiftUI); `nil` falls back to `hitFrame`.
    var contentBounds: CGRect? { get }

    var childSubgraph: Subgraph? { get set }

    var childViewSubgraph: Subgraph? { get set }

    var exclusionPolicy: GestureResponderExclusionPolicy { get }

    var label: String? { get }

    var gestureGraph: GestureGraph { get }

    var relatedAttribute: AnyAttribute { get }

    func makeSubviewsGesture(inputs: _GestureInputs) -> _GestureOutputs<Void>
}

extension AnyGestureResponder {
    package var exclusionPolicy: GestureResponderExclusionPolicy { .default }

    package func makeSubviewsGesture(inputs: _GestureInputs) -> _GestureOutputs<Void> {
        _GestureOutputs(phase: inputs.failedPhase)
    }
    
    package func makeWrappedGesture(
        inputs: _GestureInputs,
        makeChild: (_GestureInputs) -> _GestureOutputs<Void>
    ) -> _GestureOutputs<Void> {
        let inputs = inputs
        let outputs: _GestureOutputs<Void> = inputs.makeDefaultOutputs()
        guard viewSubgraph.isValid else {
            return outputs
        }
        let currentSubgraph = Subgraph.current!
        let needGestureGraph = inputs.options.contains(.gestureGraph)
        childSubgraph = Subgraph(graph: (needGestureGraph ? currentSubgraph : viewSubgraph).graph)
        viewSubgraph.addChild(childSubgraph!, tag: 1)
        currentSubgraph.addChild(childSubgraph!)
        if needGestureGraph {
            childViewSubgraph = Subgraph(graph: viewSubgraph.graph)
            childSubgraph!.addChild(childViewSubgraph!, tag: 1)
        }
        childSubgraph!.apply {
            let subgraph = (childViewSubgraph ?? childSubgraph)!
            var childInputs = inputs
            childInputs.viewInputs = self.inputs
            childInputs.copyCaches()
            childInputs.viewSubgraph = subgraph
            let childOutputs = makeChild(childInputs)
            outputs.overrideDefaultValues(childOutputs)
        }
        return outputs
    }
    
    package var label: String? { nil }

    package var isCancellable: Bool {
        gestureGraph.isCancellable
    }
    
    package var requiredTapCount: Int? {
        gestureGraph.requiredTapCount
    }
    
    package func canPrevent(
        _ other: ViewResponder,
        otherExclusionPolicy: GestureResponderExclusionPolicy
    ) -> Bool {
        guard isPrioritized(over: other, otherExclusionPolicy: otherExclusionPolicy) else {
            return false
        }
        guard let other = other as? any AnyGestureResponder else {
            return true
        }
        return other.dependency == .none
    }
    
    package func shouldRequireFailure(of other: any AnyGestureResponder) -> Bool {
        guard exclusionPolicy != .simultaneous,
              other.exclusionPolicy != .simultaneous,
              let requiredTapCount,
              let otherRequiredTapCount = other.requiredTapCount,
              otherRequiredTapCount != requiredTapCount
        else {
            return other.isPrioritized(over: self, otherExclusionPolicy: exclusionPolicy) && dependency != .none
        }
        return requiredTapCount < otherRequiredTapCount
    }

    private func isPrioritized(over other: ViewResponder, otherExclusionPolicy: GestureResponderExclusionPolicy) -> Bool {
        switch (exclusionPolicy, otherExclusionPolicy) {
        case (.default, .default):
            var resonder: ResponderNode = other
            while true {
                guard resonder !== self else {
                    return false
                }
                guard let nextResponder = resonder.nextResponder else {
                    return true
                }
                resonder = nextResponder
            }
        case (.highPriority, .highPriority):
            var resonder: ResponderNode = other
            while true {
                guard resonder !== self else {
                    return true
                }
                guard let nextResponder = resonder.nextResponder else {
                    return false
                }
                resonder = nextResponder
            }
        case (.highPriority, .default):
            return true
        default:
            return false
        }
    }

    private var dependency: GestureDependency {
        gestureGraph.gestureDependency
    }
}

// MARK: - GestureResponder

private class GestureResponder<Modifier>: DefaultLayoutViewResponder, AnyGestureResponder where Modifier: GestureViewModifier {
    let modifier: Attribute<Modifier>

    var childSubgraph: Subgraph?

    var childViewSubgraph: Subgraph?

    lazy var gestureGraph: GestureGraph = {
        GestureGraph(rootResponder: self)
    }()

    lazy var bindingBridge: EventBindingBridge & GestureGraphDelegate = {
        let bridge = inputs.makeEventBindingBridge(bindingManager: gestureGraph.eventBindingManager, responder: self)
        gestureGraph.delegate = bridge
        return bridge
    }()

    var _gestureContainer: AnyObject?

    // [wandr] Approach A: this gesture's own (global) layout frame, kept in sync by GestureFilter.
    // A gesture is hit-testable via its own frame regardless of its content's view type (shape,
    // stack, text) — no per-view-type leaf responders needed.
    var hitFrame: CGRect = .zero

    // [wandr] Whether this gesture participates in hit-testing (driven by `.allowsHitTesting`).
    var hitTestable: Bool = true

    // [wandr] Local→global transform kept in sync by GestureFilter (from `inputs.transform`). Under
    // an `.offset`/GeometryEffect the layout `position` is reset to zero and the offset lives here,
    // so a global hit point must be inverse-mapped through this before testing the local `hitFrame`.
    var viewTransform: ViewTransform = ViewTransform()

    // [wandr] Content-shape hit region: the union of the gesture content's DRAWN DisplayList item
    // frames (in the same local space as `hitFrame`). SwiftUI hit-tests where content is actually
    // drawn, not the full layout frame — e.g. a board centered in a greedy GeometryReader is only
    // hittable over the board, not the transparent padding. `nil` = no display content yet; fall
    // back to `hitFrame`. Kept in sync by GestureFilter.
    var contentBounds: CGRect? = nil

    init(modifier: Attribute<Modifier>, inputs: _ViewInputs) {
        self.modifier = modifier
        super.init(inputs: inputs)
    }

    var gestureType: any Any.Type {
        Modifier.ContentGesture.self
    }

    var producesVoidValue: Bool {
        Modifier.ContentGesture.Value.self == Void.self
    }

    var relatedAttribute: AnyAttribute {
        modifier.identifier
    }

    var eventSources: [any EventBindingSource] {
        bindingBridge.eventSources
    }

    var exclusionPolicy: GestureResponderExclusionPolicy {
        Modifier.Combiner.exclusionPolicy
    }

    var label: String? {
        guard viewSubgraph.isValid else { return nil }
        return Graph.withoutUpdate {
            viewSubgraph.apply {
                modifier.name.value
            }
        } ?? gestureGraph.gestureLabel
    }

    var isValid: Bool {
        _gestureContainer != nil && viewSubgraph.isValid
    }

    func detachContainer() {
        _gestureContainer = nil
    }

    func makeSubviewsGesture(inputs: _GestureInputs) -> _GestureOutputs<Void> {
        super.makeGesture(inputs: inputs)
    }

    override var gestureContainer: AnyObject? {
        guard let gestureContainer = _gestureContainer else {
            guard viewSubgraph.isValid else {
                return nil
            }
            _gestureContainer = inputs.makeGestureContainer(responder: self)
            return _gestureContainer!
        }
        return gestureContainer
    }

    override func containsGlobalPoints(
        _ points: [PlatformPoint],
        cacheKey: UInt32?,
        options: ViewResponder.ContainsPointsOptions
    ) -> ViewResponder.ContainsPointsResult {
        let result = super.containsGlobalPoints(points, cacheKey: cacheKey, options: options)
        // [wandr] Hit-test against this gesture's drawn content region: `hitFrame` restricted to the
        // content's drawn bounds (`contentBounds`) when known — SwiftUI hit-tests where content
        // actually draws, not the full layout frame. Each global point is inverse-mapped into this
        // gesture's local space (where `hitFrame`/`contentBounds` live) so `.offset`/GeometryEffect is
        // honored. Falls back to `hitFrame`. Matches EventBindingManager.bindResponders.
        let hitRegion: CGRect = {
            guard let cb = contentBounds else { return hitFrame }
            let r = hitFrame.intersection(cb)
            return (r.isNull || r.isEmpty) ? hitFrame : r
        }()
        var mask = result.mask
        for index in points.indices
        where hitRegion.contains(viewTransform.convert(.localToSpace(.global), point: points[index])) {
            mask[index] = true
        }
        // Bind to THIS gesture (ViewGraph.sendEvents needs an AnyGestureResponder), not content
        // leaves: keep only nested gesture responders so hitTest stops here and returns the gesture.
        return ContainsPointsResult(
            mask: mask,
            priority: options.contains(.useZDistanceAsPriority) ? ViewResponder.gestureContainmentPriority : result.priority,
            children: result.children.filter { $0 is any AnyGestureResponder }
        )
    }

    override func bindEvent(_ event: any EventType) -> ResponderNode? {
        guard GestureContainerFeature.isEnabled else {
            return super.bindEvent(event)
        }
        guard let hitTestableEvent = HitTestableEvent(event) else {
            return nil
        }
        return hitTest(
            globalPoint: hitTestableEvent.hitTestLocation,
            radius: hitTestableEvent.hitTestRadius
        )
    }

    override func makeGesture(inputs: _GestureInputs) -> _GestureOutputs<Void> {
        makeWrappedGesture(inputs: inputs) { childInputs in
            let childViewInputs = childInputs.viewInputs
            let outputs: _GestureOutputs<Void> = {
                if childInputs.options.contains(.skipCombiners) {
                    let childGesture = Attribute(GestureViewChild(
                        modifier: modifier,
                        isEnabled: childViewInputs.isEnabled,
                        viewPhase: childViewInputs.viewPhase
                    ))
                    return AnyGesture<Void>.makeDebuggableGesture(
                        gesture: _GraphValue(childGesture),
                        inputs: childInputs
                    )
                } else {
                    let childGesture = Attribute(CombiningGestureViewChild(
                        modifier: modifier,
                        isEnabled: childViewInputs.isEnabled,
                        viewPhase: childViewInputs.viewPhase,
                        node: self
                    ))
                    return Modifier.Combiner.Result.makeDebuggableGesture(
                        gesture: _GraphValue(childGesture),
                        inputs: childInputs
                    )
                }
            }()
            guard childInputs.options.contains(.includeDebugOutput) else {
                return outputs
            }
            var wrappedOutputs = outputs
            wrappedOutputs.debugData = Attribute(GestureViewDebug(
                modifier: modifier,
                debugData: OptionalAttribute(outputs.debugData)
            ))
            return wrappedOutputs
        }
    }

    override func resetGesture() {
        childSubgraph = nil
        childViewSubgraph = nil
        super.resetGesture()
    }

    override func extendPrintTree(string: inout String) {
        string.append("\(Modifier.ContentGesture.self)")
    }
}

// MARK: - GestureAccessibilityProvider

package protocol GestureAccessibilityProvider {
    nonisolated static func makeGesture(
        mask: @autoclosure () -> Attribute<GestureMask>,
        inputs: _ViewInputs,
        outputs: inout _ViewOutputs
    )
}

// MARK: - SimultaneousGestureModifier

struct SimultaneousGestureModifier<T>: GestureViewModifier where T: Gesture {
    var gesture: T
    var name: String?
    var gestureMask: GestureMask

    init(
        _ gesture: T,
        name: String?,
        gestureMask: GestureMask
    ) {
        self.gesture = gesture
        self.name = name
        self.gestureMask = gestureMask
    }

    typealias ContentGesture = T
    typealias Combiner = SimultaneousGestureCombiner
}

// MARK: - HighPriorityGestureModifier

struct HighPriorityGestureModifier<T>: GestureViewModifier where T: Gesture {
    var gesture: T
    var name: String?
    var gestureMask: GestureMask

    init(
        _ gesture: T,
        name: String?,
        gestureMask: GestureMask
    ) {
        self.gesture = gesture
        self.name = name
        self.gestureMask = gestureMask
    }

    typealias ContentGesture = T
    typealias Combiner = HighPriorityGestureCombiner
}

// MARK: - GestureFilter

private struct GestureFilter<Modifier>: StatefulRule where Modifier: GestureViewModifier {
    typealias Value = [ViewResponder]

    @Attribute var children: [ViewResponder]

    @Attribute var modifier: Modifier

    // [wandr] The modified view's global layout frame — keeps GestureResponder.hitFrame in sync so
    // the gesture is hit-testable via its own frame (Approach A).
    @Attribute var position: ViewOrigin

    @Attribute var size: CGSize

    // [wandr] `.allowsHitTesting(false)` up the tree → this subtree's gesture is excluded from
    // hit-testing (EventBindingManager.bindResponders skips it), so an overlay can disable the
    // background it covers instead of the background stealing events.
    @Attribute var hitTestable: Bool

    // [wandr] The local→global transform (`.offset`/`.scaleEffect`/… GeometryEffects). Kept on the
    // responder so hit-testing can inverse-map the global point into the space `hitFrame` lives in.
    @Attribute var transform: ViewTransform

    // [wandr] The gesture content's DisplayList (present when the content draws). Its item frames —
    // unioned — give the drawn content bounds, used to restrict the hit region to actually-drawn
    // content (content-shape hit-testing), instead of the full layout `hitFrame`.
    @OptionalAttribute var contentDisplayList: DisplayList?

    var inputs: _ViewInputs

    var viewSubgraph: Subgraph

    lazy var responder: GestureResponder<Modifier> = {
        viewSubgraph.apply {
            GestureResponder(
                modifier: $modifier,
                inputs: inputs
            )
        }
    }()

    mutating func updateValue() {
        let responder = responder
        let (children, childrenChanged) = $children.changedValue()
        if childrenChanged {
            responder.children = children
        }
        responder.hitFrame = CGRect(origin: position, size: size)
        responder.hitTestable = hitTestable
        responder.viewTransform = transform
        if let list = contentDisplayList {
            let bounds = wandrDisplayListDrawnBounds(list)
            responder.contentBounds = bounds.isNull || bounds.isEmpty ? nil : bounds
        } else {
            responder.contentBounds = nil
        }
        if !hasValue {
            value = [self.responder]
        }
    }
}

// [wandr] Union of a DisplayList's DRAWN item frames — the content-shape bounds used to restrict a
// gesture's hit region to where content actually draws (see GestureResponder.contentBounds). Each
// `Item.frame` is already expressed in THIS list's coordinate space and already bounds that item's
// (possibly transformed/positioned) content — which is the same space as GestureResponder.hitFrame.
// So we union only the top-level item frames and do NOT recurse into `.effect`/`.states` sublists:
// those sublists are in the item's own PRE-transform space (e.g. a `.position`-ed board's children
// sit at the un-centered origin), and mixing them in would wrongly stretch the bounds back to (0,0).
// `.empty` items draw nothing and are skipped.
private func wandrDisplayListDrawnBounds(_ list: DisplayList) -> CGRect {
    var bounds = CGRect.null
    for item in list.items {
        if case .empty = item.value { continue }
        bounds = bounds.union(item.frame)
    }
    return bounds
}

// MARK: - EmptyGestureAccessibilityProvider

struct EmptyGestureAccessibilityProvider: GestureAccessibilityProvider {
    nonisolated static func makeGesture(
        mask: @autoclosure () -> Attribute<GestureMask>,
        inputs: _ViewInputs,
        outputs: inout _ViewOutputs
    ) {
        _openSwiftUIEmptyStub()
    }
}

// MARK: - Inputs + gestureAccessibilityProvider

extension _GraphInputs {
    private struct GestureAccessibilityProviderKey: GraphInput {
        static let defaultValue: (any GestureAccessibilityProvider.Type) = EmptyGestureAccessibilityProvider.self
    }

    package var gestureAccessibilityProvider: (any GestureAccessibilityProvider.Type) {
        get { self[GestureAccessibilityProviderKey.self] }
        set { self[GestureAccessibilityProviderKey.self] = newValue }
    }
}

extension _ViewInputs {
    package var gestureAccessibilityProvider: (any GestureAccessibilityProvider.Type) {
        get { base.gestureAccessibilityProvider }
        set { base.gestureAccessibilityProvider = newValue }
    }
}

// MARK: - GestureViewChild

private struct GestureViewChild<Modifier>: Rule where Modifier: GestureViewModifier {
    @Attribute var modifier: Modifier
    @Attribute var isEnabled: Bool
    @Attribute var viewPhase: _GraphInputs.Phase

    typealias Value = AnyGesture<Void>

    var value: Value {
        let shouldReceiveEvents = modifier.gestureMask.contains(.gesture) && isEnabled
        guard shouldReceiveEvents else {
            return AnyGesture(EmptyGesture())
        }
        return AnyGesture(modifier.gesture.map { _ in })
    }
}

// MARK: - CombiningGestureViewChild

private struct CombiningGestureViewChild<Modifier>: Rule where Modifier: GestureViewModifier {
    @Attribute var modifier: Modifier
    @Attribute var isEnabled: Bool
    @Attribute var viewPhase: _GraphInputs.Phase

    let node: any AnyGestureResponder

    typealias Value = Modifier.Combiner.Result

    @inline(__always)
    private var shouldReceiveEvents: Bool {
        modifier.gestureMask.contains(.gesture) && isEnabled
    }

    @inline(__always)
    private var shouldReceiveSubviewEvents: Bool {
        modifier.gestureMask.contains(.subviews)
    }

    @inline(__always)
    private var subviewsGesture: AnyGesture<Void> {
        if modifier.gestureMask.contains(.subviews) {
            return AnyGesture(SubviewsGesture(node: node))
        } else {
            return AnyGesture(EmptyGesture())
        }
    }

    @inline(__always)
    private var contentGesture: AnyGesture<Void> {
        if shouldReceiveEvents {
            AnyGesture(modifier.gesture
                .modifier(ContentGesture<Modifier.ContentGesture.Value>())
            )
        } else {
            AnyGesture(EmptyGesture())
        }
    }

    var value: Value {
        Modifier.Combiner.combine(subviewsGesture, contentGesture)
    }
}

// MARK: - GestureViewDebug

private struct GestureViewDebug<Modifier>: Rule where Modifier: GestureViewModifier {
    @Attribute var modifier: Modifier
    @OptionalAttribute var debugData: GestureDebug.Data?

    typealias Value = GestureDebug.Data

    var value: GestureDebug.Data {
        guard let debugData else {
            return GestureDebug.Data()
        }
        return GestureDebug.Data(
            kind: .gesture,
            type: Modifier.ContentGesture.self,
            children: [debugData],
            phase: debugData.phase,
            attribute: $modifier.identifier,
            resetSeed: debugData.resetSeed,
            frame: debugData.frame,
            properties: .init()
        )
    }
}

// MARK: - SubviewsGesture

private struct SubviewsGesture: PrimitiveGesture, PrimitiveDebuggableGesture {
    typealias Value = ()

    typealias Body = Never

    let node: AnyGestureResponder

    static func _makeGesture(gesture: _GraphValue<Self>, inputs: _GestureInputs) -> _GestureOutputs<Void> {
        let outputs: _GestureOutputs<Void> = inputs.makeIndirectOutputs()
        let currentSubgraph = Subgraph.current!
        let subviewValue = Attribute(SubviewsPhase(
            gesture: gesture.value,
            resetSeed: inputs.resetSeed,
            inputs: inputs,
            outputs: outputs,
            parentSubgraph: currentSubgraph,
            oldNode: nil,
            oldSeed: 0,
            childSubgraph: nil,
            childPhase: .init(),
            childDebugData: .init()
        ))
        outputs.setIndirectDependency(subviewValue.identifier)
        return outputs
    }
}

// MARK: - SimultaneousGestureCombiner

struct SimultaneousGestureCombiner: GestureCombiner {
    typealias Base = SimultaneousGesture<AnyGesture<Void>, AnyGesture<Void>>

    typealias Result = _MapGesture<Base, Void>

    static func combine(
        _ first: AnyGesture<Void>,
        _ second: AnyGesture<Void>
    ) -> Result {
        first.simultaneously(with: second).map { _ in }
    }

    static var exclusionPolicy: GestureResponderExclusionPolicy { .simultaneous }
}

// MARK: - HighPriorityGestureCombiner

struct HighPriorityGestureCombiner: GestureCombiner {
    typealias Base = ExclusiveGesture<AnyGesture<Void>, AnyGesture<Void>>

    typealias Result = _MapGesture<Base, Void>

    static func combine(
        _ first: AnyGesture<Void>,
        _ second: AnyGesture<Void>
    ) -> Result {
        second.exclusively(before: first).map { _ in }
    }

    static var exclusionPolicy: GestureResponderExclusionPolicy { .highPriority }
}

// MARK: - SubviewsPhase

private struct SubviewsPhase: StatefulRule, ObservedAttribute {
    struct Value {
        var phase: GesturePhase<Void>
        var debugData: GestureDebug.Data
    }

    @Attribute var gesture: SubviewsGesture
    @Attribute var resetSeed: UInt32
    let inputs: _GestureInputs
    let outputs: _GestureOutputs<Void>
    let parentSubgraph: Subgraph
    var oldNode: AnyGestureResponder?
    var oldSeed: UInt32
    var childSubgraph: Subgraph?
    @OptionalAttribute var childPhase: GesturePhase<Void>?
    @OptionalAttribute var childDebugData: GestureDebug.Data?

    mutating func updateValue() {
        let node = gesture.node
        if resetSeed != oldSeed || childSubgraph == nil || oldNode !== node {
            if let childSubgraph {
                outputs.detachIndirectOutputs()
                self.childSubgraph = nil
                _childPhase = .init()
                childSubgraph.willInvalidate(isInserted: true)
                childSubgraph.invalidate()
            }
            oldNode?.resetGesture()

            let newSubgraph = Subgraph(graph: parentSubgraph.graph)
            childSubgraph = newSubgraph
            parentSubgraph.addChild(newSubgraph)
            let childOutputs = newSubgraph.apply {
                var childInputs = inputs
                childInputs.copyCaches()
                let childOutputs = node.makeSubviewsGesture(inputs: childInputs)
                outputs.attachIndirectOutputs(childOutputs)
                return childOutputs
            }
            _childPhase = OptionalAttribute(childOutputs.phase)
            _childDebugData = OptionalAttribute(childOutputs.debugData)
            oldSeed = resetSeed
            oldNode = node
        }
        value = Value(
            phase: childPhase ?? .failed,
            debugData: childDebugData ?? GestureDebug.Data()
        )
    }

    func destroy() {
        oldNode?.resetGesture()
    }
}

// MARK: - ContentPhase

private struct ContentPhase<Value>: ResettableGestureRule {
    @Attribute var phase: GesturePhase<Value>
    @Attribute var resetSeed: UInt32
    var lastResetSeed: UInt32

    typealias Value = GesturePhase<Void>

    mutating func updateValue() {
        guard resetIfNeeded() else {
            return
        }
        value = phase.withValue(())
    }
}

// MARK: - ContentGesture

private struct ContentGesture<V>: GestureModifier {
    typealias Value = Void

    typealias BodyValue = V

    nonisolated static func _makeGesture(
        modifier: _GraphValue<ContentGesture<V>>,
        inputs: _GestureInputs,
        body: (_GestureInputs) -> _GestureOutputs<V>
    ) -> _GestureOutputs<Void> {
        let outputs = body(inputs)
        let phase = Attribute(ContentPhase(
            phase: outputs.phase,
            resetSeed: inputs.resetSeed,
            lastResetSeed: 0
        ))
        return outputs.withPhase(phase)
    }
}
