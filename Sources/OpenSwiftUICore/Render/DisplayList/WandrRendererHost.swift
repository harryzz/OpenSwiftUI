//
//  WandrRendererHost.swift
//  OpenSwiftUICore
//
//  Host for the wandr Option-B renderer — a sibling of StdoutRendererHost that
//  configures the ViewRenderer with `.wandr(options)` so a render pass walks the
//  resolved DisplayList into the caller's WandrDrawSink (→ wasi:canvas CGContext).

#if !OPENSWIFTUI_SWIFTUI_RENDERER
import Foundation

// MARK: - WandrRendererHost

final package class WandrRendererHost<Content>: ViewRendererHost, ViewGraphRenderDelegate, EventGraphHost, EventBindingManagerDelegate where Content: View {
    typealias RootView = ModifiedContent<Content, HitTestBindingModifier>

    package let viewGraph: ViewGraph
    package let renderer: DisplayList.ViewRenderer
    package let rootView: Content
    package let environment: EnvironmentValues
    package let options: _RendererConfiguration.WandrOptions

    // [wandr] Pointer/gesture event routing. The host owns the top-level binding
    // manager that `WandrApp.wandrSendPointer` feeds; it binds an incoming event to
    // a responder (hit-test / structural) and forwards to that responder's GestureGraph.
    package let eventBindingManager: EventBindingManager = .init()

    package var currentTimestamp: Time = .zero
    package var propertiesNeedingUpdate: ViewRendererHostProperties = .all
    package var renderingPhase: ViewRenderingPhase = .none
    package var externalUpdateCount: Int = .zero

    package init(
        rootView: Content,
        environment: EnvironmentValues,
        options: _RendererConfiguration.WandrOptions
    ) {
        self.rootView = rootView
        self.environment = environment
        self.options = options
        Update.begin()
        // The wandr renderer needs layout + display list output, plus view responders
        // so `.onTapGesture` / `DragGesture` produce a hit-testable responder tree.
        viewGraph = ViewGraph(rootViewType: RootView.self, requestedOutputs: [.displayList, .layout, .viewResponders])
        renderer = DisplayList.ViewRenderer(
            platform: .init(definition: WandrPlatformViewDefinition.self)
        )
        renderer.configuration = .wandr(options)
        renderer.host = self
        initializeViewGraph()
        // [wandr] Wire the binding manager AFTER the graph is up; `host` is read on the
        // event path to find `responderNode` / forward events.
        eventBindingManager.host = self
        eventBindingManager.delegate = self
        Update.end()
    }

    // MARK: - EventGraphHost

    package var responderNode: ResponderNode? {
        viewGraph.responderNode
    }

    package var focusedResponder: ResponderNode? {
        eventBindingManager.focusedResponder
    }

    // MARK: - EventBindingManagerDelegate

    package func didUpdate(
        phase: GesturePhase<Void>,
        in eventBindingManager: EventBindingManager
    ) {
        // [wandr] Mirror CAHostingLayer: once a gesture sequence terminates, drop the
        // bindings so the next down/up starts fresh. Reset is a no-op subgraph-wise
        // (we never force-tear-down — see resetEvents) so this is trap-safe.
        guard phase.isTerminal else {
            return
        }
        eventBindingManager.reset(resetForwardedEventDispatchers: false)
    }

    package func renderOnce() {
        // [wandr] Defer subgraph TEARDOWN across the whole render (not per-UpdateStack), so a child
        // subgraph invalidated during reconciliation isn't freed+recycled while a LATER reader in the
        // same render still resolves a weak/indirect ref into it (the move-2 use-after-free). This is
        // the side-effect-free half of what withMainThreadHandler does — it toggles ONLY
        // _deferring_subgraph_invalidation (the teardown gate), not the main-thread update dispatch
        // that regressed move 0. endDeferring drains+reclaims at scope exit (no leak). Matches Apple.
        viewGraph.graph.withoutSubgraphInvalidation {
            render(interval: .zero, targetTimestamp: nil)
        }
    }

    /// [wandr] Drive ONE animation frame: advance the animation clock by `interval` seconds,
    /// re-evaluate invalidated bodies, interpolate active value animations (`.animation(_:value:)`),
    /// and render. Unlike `renderOnce` (interval `.zero` = frozen clock → animations snap to target),
    /// this is what makes springs actually interpolate. Returns `true` while an animation is still in
    /// flight (the graph scheduled a finite `nextUpdate`), so the guest keeps driving frames fast;
    /// `false` once everything settles and the guest can drop back to idle pacing.
    package func renderFrame(interval: Double) -> Bool {
        viewGraph.graph.withoutSubgraphInvalidation {
            render(interval: interval, targetTimestamp: nil)
        }
        return viewGraph.nextUpdate.views.time.seconds.isFinite
    }

    /// Re-walk the current (already-computed) display list into `options.sink`, without
    /// re-running the graph. The guest calls this every frame (after pointing the sink's
    /// CGContext at the new back-buffer) so a static scene repaints under double-buffering.
    package func redraw() {
        // [wandr] displayList() pulls any pending dirty graph update; defer teardown across it too
        // (see renderOnce) so the move-driving update can't free a still-read subgraph mid-pass.
        viewGraph.graph.withoutSubgraphInvalidation {
            Update.begin()
            let (list, version) = viewGraph.displayList()
            Update.end()
            list.renderToWandrSink(options.sink, surface: options.surface, version: version)
        }
    }

    package func updateRootView() {
        viewGraph.setRootView(Self.makeRootView(rootView))
    }

    package func updateEnvironment() {
        viewGraph.setEnvironment(environment)
    }

    package func updateTransform() {
        viewGraph.invalidateTransform()
    }

    package func updateSize() {
        viewGraph.setProposedSize(options.surface)
    }

    package func updateSafeArea() {
        viewGraph.setSafeAreaInsets(.zero)
    }

    package func updateContainerSize() {
        viewGraph.setContainerSize(.fixed(options.surface))
    }

    package func updateFocusStore() {}

    package func updateFocusedItem() {}

    package func updateFocusedValues() {}

    package func updateAccessibilityEnvironment() {}

    package func `as`<T>(_ type: T.Type) -> T? {
        if EventGraphHost.self == T.self {
            // [wandr] Safe runtime cast (NOT the unsafeBitCast-of-existential trick used
            // below): casting an existential of EventGraphHost across protocol types via
            // unsafeBitCast corrupts ARC on wasm32-wasip1. `self as? T` is sound.
            return self as? T
        } else if ViewGraphRenderDelegate.self == T.self {
            return unsafeBitCast(self as any ViewGraphRenderDelegate, to: T.self)
        } else if DisplayList.ViewRenderer.self == T.self {
            return unsafeBitCast(renderer, to: T.self)
        } else {
            return nil
        }
    }

    package func requestUpdate(after delay: Double) {}

    package var renderingRootView: AnyObject {
        self
    }

    package func updateRenderContext(_ context: inout ViewGraphRenderContext) {
        context.contentsScale = 1.0
        context.opaqueBackground = false
    }

    package func withMainThreadRender(wasAsync: Bool, _ body: () -> Time) -> Time {
        body()
    }
}

private final class WandrPlatformViewDefinition: PlatformViewDefinition, @unchecked Sendable {}
#endif
