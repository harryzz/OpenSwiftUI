//
//  WandrApp.swift
//  OpenSwiftUI
//
//  Sibling of runStdoutApp — drives one render pass of an App through the wandr
//  Option-B renderer, pushing the resolved DisplayList into the caller's
//  WandrDrawSink. The wandr guest calls this from its frame handler (or once for
//  a static scene); the sink draws into a wasi:canvas CGContext.

#if !OPENSWIFTUI_SWIFTUI_RENDERER
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(WASI)
import WASILibc
#endif
import Foundation
@_spi(ForOpenSwiftUIOnly)
import OpenSwiftUICore

// MARK: - runWandrApp

// The host is retained for the process lifetime: its teardown runs
// GraphHost.invalidate -> Subgraph.forEach, an arg-closure that still hits the
// swiftcall mislowering on wasm (the same wall runStdoutApp dodges with exit(0)).
// A guest keeps a single host alive across frames anyway, so never deinit it.
// (Remove the leak once Subgraph.forEach has a *C variant.)
nonisolated(unsafe) private var _wandrHostKeepAlive: AnyObject?
nonisolated(unsafe) private var _wandrRedraw: (() -> Void)?
nonisolated(unsafe) private var _wandrRender: (() -> Void)?
nonisolated(unsafe) private var _wandrRenderFrame: ((Double) -> Bool)?

// [wandr debug] flush-safe stderr trace to locate the wasm render-drive hang (survives timeout-kill).
#if os(WASI)
@inline(never) private func _wandrTrace(_ s: String) { fputs("[WANDR] \(s)\n", stderr); fflush(stderr) }
#else
@inline(never) private func _wandrTrace(_ s: String) {}
#endif

/// Build `app`'s graph + first scene and render it once through the wandr renderer
/// into `options.sink`. The host is retained for the process lifetime (a guest keeps
/// one host across frames; this also dodges the Subgraph.forEach teardown wall).
/// Call `wandrRedraw()` each subsequent frame to repaint under double-buffering.
@_spi(WandrRenderer)
public func renderWandrAppOnce(
    _ app: some App,
    options: _RendererConfiguration.WandrOptions
) {
    // The wandr renderer declares its capabilities here (the platform/renderer layer — NOT
    // core view logic). The host shapes text itself (wasi:canvas paragraph / Skia) and view
    // transitions aren't implemented yet, so core falls back accordingly. Apple builds never
    // call this and keep the defaults (transitions on, in-framework glyph text).
    _RenderingCapabilities.current = _RenderingCapabilities(
        supportsViewTransitions: false,
        usesHostShapedText: true
    )
    _wandrTrace("renderWandrAppOnce: enter")
    Update.dispatchImmediately(reason: nil) {
        _wandrTrace("dispatchImmediately: in")
        let graph = AppGraph(app: app)
        _wandrTrace("AppGraph created")
        graph.instantiate()
        _wandrTrace("instantiate DONE")
        AppGraph.shared = graph
        guard let item = graph.rootSceneList?.items.first else {
            _wandrTrace("no root scene item")
            return
        }
        _wandrTrace("rootScene ok")
        let rootView = item.value.view
            .frame(width: options.surface.width, height: options.surface.height)
        let host = WandrRendererHost(
            rootView: rootView,
            environment: item.environment,
            options: options
        )
        _wandrTrace("host created")
        _wandrHostKeepAlive = host
        _wandrRedraw = { host.redraw() }
        // Re-render must run inside an update transaction (like the initial render below) so a
        // re-evaluated body that creates new attributes has a current subgraph — otherwise
        // Attribute.init(value:) hits "attempting to create attribute with no subgraph".
        _wandrRender = { Update.dispatchImmediately(reason: nil) { host.renderOnce() } }
        _wandrRenderFrame = { interval in
            var pending = false
            Update.dispatchImmediately(reason: nil) { pending = host.renderFrame(interval: interval) }
            return pending
        }
        _wandrTrace("renderOnce START")
        host.renderOnce()
        _wandrTrace("renderOnce DONE")
    }
    _wandrTrace("renderWandrAppOnce: exit")
}

/// Re-walk the current display list into the sink passed to `renderWandrAppOnce`.
/// The guest points the sink's CGContext at the new back-buffer, then calls this.
@_spi(WandrRenderer)
public func wandrRedraw() {
    _wandrRedraw?()
}

/// Apply a state mutation (e.g. a @State write from a raw reactor input handler) INSIDE an
/// OpenSwiftUI update transaction, so the change is registered as a graph invalidation and the
/// next `wandrRedraw()` re-evaluates the affected view bodies. The host calls input handlers
/// outside any transaction, so a bare @State write would not invalidate anything.
@_spi(WandrRenderer)
public func wandrApplyChange(_ body: () -> Void) {
    Update.dispatchImmediately(reason: nil, body)
}

/// Re-RUN the graph (re-evaluate invalidated view bodies) and render the result into the sink.
/// Unlike `wandrRedraw()` (which only re-walks the already-computed display list), this picks up
/// state changes. Call it on the frame after a `wandrApplyChange`.
@_spi(WandrRenderer)
public func wandrRender() {
    _wandrRender?()
}

/// Drive ONE animation frame: advance the animation clock by `interval` seconds, re-evaluate
/// invalidated bodies, interpolate active value animations, and render. Returns `true` while an
/// animation is still in flight (keep calling each frame at a fast cadence); `false` once settled
/// (the guest can drop back to idle pacing). This is what makes `.animation(_:value:)` springs
/// interpolate instead of snapping — `wandrRender()`/`renderOnce()` freeze the clock at interval 0.
@_spi(WandrRenderer)
public func wandrRenderFrame(_ interval: Double) -> Bool {
    _wandrRenderFrame?(interval) ?? false
}
#endif
