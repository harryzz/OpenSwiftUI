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

final package class WandrRendererHost<Content>: ViewRendererHost, ViewGraphRenderDelegate where Content: View {
    typealias RootView = ModifiedContent<Content, HitTestBindingModifier>

    package let viewGraph: ViewGraph
    package let renderer: DisplayList.ViewRenderer
    package let rootView: Content
    package let environment: EnvironmentValues
    package let options: _RendererConfiguration.WandrOptions

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
        // The wandr renderer (like stdout) only needs layout + display list output.
        viewGraph = ViewGraph(rootViewType: RootView.self, requestedOutputs: [.displayList, .layout])
        renderer = DisplayList.ViewRenderer(
            platform: .init(definition: WandrPlatformViewDefinition.self)
        )
        renderer.configuration = .wandr(options)
        renderer.host = self
        initializeViewGraph()
        Update.end()
    }

    package func renderOnce() {
        render(interval: .zero, targetTimestamp: nil)
    }

    /// Re-walk the current (already-computed) display list into `options.sink`, without
    /// re-running the graph. The guest calls this every frame (after pointing the sink's
    /// CGContext at the new back-buffer) so a static scene repaints under double-buffering.
    package func redraw() {
        Update.begin()
        let (list, version) = viewGraph.displayList()
        Update.end()
        list.renderToWandrSink(options.sink, surface: options.surface, version: version)
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
        if ViewGraphRenderDelegate.self == T.self {
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
