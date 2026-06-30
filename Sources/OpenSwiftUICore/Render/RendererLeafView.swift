//
//  RendererLeafView.swift
//  OpenSwiftUICore
//
//  Audited for 6.0.87
//  ID: 65609C35608651F66D749EB1BD9D2226 (SwiftUICore)
//  Status: WIP

package import Foundation
import OpenAttributeGraphShims

// MARK: - RendererLeafView [TODO]

package protocol RendererLeafView: ContentResponder, PrimitiveView, UnaryView {
    static var requiresMainThread: Bool { get }
    func content() -> DisplayList.Content.Value
}

extension RendererLeafView {
    package static var requiresMainThread: Bool {
        false
    }
    
    func contains(points: [PlatformPoint], size: CGSize) -> BitVector64 {
        _openSwiftUIUnimplementedFailure()
    }
    
    package static func makeLeafView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        // TODO
        var outputs = _ViewOutputs()
        // FIXME
        if inputs.preferences.requiresDisplayList {
            outputs.preferences.displayList = Attribute(
                LeafDisplayList(
                    identity: .init(),
                    view: view.value,
                    position: inputs.animatedPosition(),
                    size: inputs.animatedCGSize(),
                    containerPosition: inputs.containerPosition,
                    options: .defaultValue,
                    contentSeed: .init()
                )
            )
        }
        // [wandr] Geometric hit-testing: emit a leaf ViewResponder carrying this view's frame so
        // gestures can test the hit location against their content. Without this, a gesture's
        // children are empty and `containsGlobalPoints` returns an empty mask (the old structural,
        // location-blind fallback). The frame uses the same animated position/size the display list
        // draws with. See LeafViewRespondersRule.
        if inputs.preferences.requiresViewResponders {
            outputs.preferences.viewResponders = Attribute(
                LeafViewRespondersRule(
                    position: inputs.animatedPosition(),
                    size: inputs.animatedCGSize()
                )
            )
        }
        return outputs
    }
}

// MARK: - RendererLeafViewResponder

/// [wandr] A geometry-carrying leaf responder: reports which of the queried global points fall
/// inside its (axis-aligned) frame. This is the geometry that lets `ViewResponder.hitTest` resolve
/// a tap/drag to the gesture whose content was actually hit. Transformed hit regions
/// (.offset/.scaleEffect/.rotationEffect) and shape-precise containment are follow-ups.
package final class RendererLeafViewResponder: ViewResponder {
    package var frame: CGRect = .zero

    package override func containsGlobalPoints(
        _ points: [PlatformPoint],
        cacheKey: UInt32?,
        options: ContainsPointsOptions
    ) -> ContainsPointsResult {
        guard allowHitTesting, opacity >= ViewResponder.minOpacityForHitTest else {
            return ContainsPointsResult(mask: [], priority: 0, children: [])
        }
        var mask: BitVector64 = []
        for index in points.indices where frame.contains(points[index]) {
            mask[index] = true
        }
        return ContainsPointsResult(mask: mask, priority: 0, children: [])
    }

    package override var descriptionName: String { "RendererLeaf" }
}

// MARK: - LeafViewRespondersRule

/// [wandr] Builds (once) and keeps the leaf's `RendererLeafViewResponder` frame in sync with the
/// view's global position/size. `position` is the view's origin in the root/global space the event
/// `globalLocation` is delivered in, so the frame is used directly for global hit-testing.
private struct LeafViewRespondersRule: StatefulRule, CustomStringConvertible {
    @Attribute var position: ViewOrigin
    @Attribute var size: CGSize

    lazy var responder = RendererLeafViewResponder()

    typealias Value = [ViewResponder]

    mutating func updateValue() {
        let responder = responder
        responder.frame = CGRect(origin: position, size: size)
        if !hasValue {
            value = [responder]
        }
    }

    var description: String { "LeafViewResponders" }
}

// MARK: - LeafViewLayout

package protocol LeafViewLayout {
    func spacing() -> Spacing
    func sizeThatFits(in proposedSize: _ProposedSize) -> CGSize
}

extension LeafViewLayout {
    package func spacing() -> Spacing {
        Spacing()
    }

    package static func makeLeafLayout(_ outputs: inout _ViewOutputs, view: _GraphValue<Self>, inputs: _ViewInputs) {
        guard inputs.requestsLayoutComputer else {
            return
        }
        outputs.layoutComputer = Attribute(LeafLayoutComputer(view: view.value))
    }
}

// MARK: - LeafLayoutComputer

private struct LeafLayoutComputer<V>: StatefulRule, AsyncAttribute, CustomStringConvertible where V: LeafViewLayout {
    @Attribute
    package var view: V

    typealias Value = LayoutComputer

    mutating func updateValue() {
        let engine = LeafLayoutEngine(view)
        update(to: engine)
    }

    var description: String { "LeafLayoutComputer" }
}

// MARK: - LeafLayoutEngine

package struct LeafLayoutEngine<V>: LayoutEngine where V: LeafViewLayout {
    package let view: V

    private var cache: ViewSizeCache

    package init(_ view: V) {
        self.view = view
        self.cache = ViewSizeCache()
    }

    package func spacing() -> Spacing {
        view.spacing()
    }

    package mutating func sizeThatFits(_ proposedSize: _ProposedSize) -> CGSize {
        let view = view
        return cache.get(proposedSize) {
            view.sizeThatFits(in: proposedSize)
        }
    }
}

// MARK: - LeafDisplayList [WIP]

private struct LeafDisplayList<V>: StatefulRule, CustomStringConvertible where V: RendererLeafView {
    let identity: DisplayList.Identity
    @Attribute var view: V
    @Attribute var position: ViewOrigin
    @Attribute var size: CGSize
    @Attribute var containerPosition: ViewOrigin
    let options: DisplayList.Options
    var contentSeed: DisplayList.Seed

    typealias Value = DisplayList

    static var flags: Flags {
        V.requiresMainThread ? .mainThread : []
    }

    mutating func updateValue() {
        let (view, viewChanged) = $view.changedValue()
        let content = view.content()
        let version = DisplayList.Version(forUpdate: ())
        if viewChanged {
            contentSeed = .init(version)
        }
        var item = DisplayList.Item(
            .content(DisplayList.Content(content, seed: contentSeed)),
            frame: CGRect(
                origin: CGPoint(position - containerPosition),
                size: size
            ),
            identity: identity,
            version: version
        )
        item.canonicalize(options: options)
        value = DisplayList(item)
    }

    var description: String { "LeafDisplayList" }
}
