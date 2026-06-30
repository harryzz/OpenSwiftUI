//
//  HitTestBindingModifier.swift
//  OpenSwiftUICore
//
//  Status: WIP
//  ID: D16C83991EAE21A87411739F6DC01498 (SwiftUICore)

package import Foundation

package typealias PlatformHitTestableEvent = HitTestableEvent

package struct HitTestBindingModifier: ViewModifier, MultiViewModifier, PrimitiveViewModifier {
    nonisolated package static func _makeView(
        modifier: _GraphValue<Self>,
        inputs: _ViewInputs,
        body: @escaping (_Graph, _ViewInputs) -> _ViewOutputs
    ) -> _ViewOutputs {
        // [wandr] This modifier wraps the whole root view (see ViewRendererHost.makeRootView).
        // It opts the subtree into producing ViewResponders and installs the wandr factories
        // that gestures need to build their EventBindingBridge / gesture container. Without
        // `requiresViewResponders`, `GestureViewModifier.makeView` never creates a
        // GestureResponder, so `.onTapGesture` would produce no responder to bind events to.
        var inputs = inputs
        inputs.preferences.requiresViewResponders = true
        if inputs.eventBindingBridgeFactory == nil {
            inputs.eventBindingBridgeFactory = WandrEventBindingBridgeFactory.self
        }
        if inputs.gestureContainerFactory == nil {
            inputs.gestureContainerFactory = WandrGestureContainerFactory.self
        }
        return body(_Graph(), inputs)
    }

    package typealias Body = Never
}

// MARK: - Wandr gesture factories

/// [wandr] The bridge that connects a gesture's GestureGraph to event delivery and action
/// dispatch. `enqueueAction` (GestureGraphDelegate) routes a gesture's callback onto the
/// Update action queue so it drains when the surrounding transaction depth returns to 0 —
/// which is why callers send pointer events inside `Update.dispatchImmediately`.
final class WandrEventBindingBridge: EventBindingBridge, GestureGraphDelegate {
    init(bindingManager: EventBindingManager) {
        super.init(eventBindingManager: bindingManager)
    }

    override func send(
        _ events: [EventID: any EventType],
        source: any EventBindingSource
    ) -> Set<EventID> {
        eventBindingManager?.send(events) ?? []
    }

    override func reset(
        eventSource: any EventBindingSource,
        resetForwardedEventDispatchers: Bool = false
    ) {
        eventBindingManager?.reset(resetForwardedEventDispatchers: resetForwardedEventDispatchers)
    }

    func enqueueAction(_ action: @escaping () -> Void) {
        Update.enqueueAction(reason: nil, action)
    }
}

enum WandrEventBindingBridgeFactory: EventBindingBridgeFactory {
    static func makeEventBindingBridge(
        bindingManager: EventBindingManager,
        responder: any AnyGestureResponder
    ) -> any EventBindingBridge & GestureGraphDelegate {
        WandrEventBindingBridge(bindingManager: bindingManager)
    }
}

/// [wandr] An opaque token a GestureResponder needs to be considered "valid" (its
/// `isValid` requires a non-nil container). We hold no platform state; the responder is
/// kept alive by the responder tree, so this is intentionally empty.
final class WandrGestureContainer {}

enum WandrGestureContainerFactory: GestureContainerFactory {
    static func makeGestureContainer(responder: any AnyGestureContainingResponder) -> AnyObject {
        WandrGestureContainer()
    }
}

// MARK: - ViewResponder hit-testing

extension ViewResponder {
    package static var hitTestKey: UInt32 {
        // [wandr] Geometric hit-test caching is not the active binding path (see below),
        // so a constant key is sufficient. Internal hit-tests pass `cacheKey: nil`, which
        // bypasses the cache entirely, so this value is never load-bearing today.
        0
    }

    package static let minOpacityForHitTest: Double = 0.001

    package func hitTest(
        globalPoint: PlatformPoint,
        radius: CGFloat,
        cacheKey: UInt32? = nil,
        options: ContainsPointsOptions = .platformDefault
    ) -> ViewResponder? {
        // [wandr] NOTE: this geometric path is NOT how taps currently bind. With
        // `GestureContainerFeature` disabled and no leaf responders carrying real frame
        // geometry, `containsGlobalPoints` returns an empty mask, so this returns nil for
        // the common case. EventBindingManager falls back to a structural search to deliver
        // a single gesture. This implementation is kept correct-shaped and trap-free for
        // when geometry/leaf responders land. Pass `cacheKey: nil` to disable caching.
        let (points, weights) = hitPoints(point: globalPoint, radius: radius)
        var mask = BitVector64()
        for index in points.indices {
            mask[index] = true
        }
        return hitTest(
            globalPoints: points,
            weights: weights,
            mask: mask,
            cacheKey: nil,
            options: options
        )
    }

    private func hitTest(
        globalPoints: [PlatformPoint],
        weights: [Double],
        mask: BitVector64,
        cacheKey: UInt32?,
        options: ContainsPointsOptions
    ) -> ViewResponder? {
        let result = containsGlobalPoints(globalPoints, cacheKey: cacheKey, options: options)
        let activeRaw = result.mask.rawValue & mask.rawValue
        guard activeRaw != 0 else {
            return nil
        }
        let activeMask = BitVector64(rawValue: activeRaw)
        for child in result.children where child !== self {
            if let hit = child.hitTest(
                globalPoints: globalPoints,
                weights: weights,
                mask: activeMask,
                cacheKey: cacheKey,
                options: options
            ) {
                return hit
            }
        }
        return self
    }
}

private func hitPoints(point: PlatformPoint, radius: CGFloat) -> ([PlatformPoint], [Double]) {
    // [wandr] Minimal point cloud: the single sample point at full weight. A radius-aware
    // cloud (rings of samples) can replace this once geometric hit-testing is the active path.
    ([point], [1.0])
}
