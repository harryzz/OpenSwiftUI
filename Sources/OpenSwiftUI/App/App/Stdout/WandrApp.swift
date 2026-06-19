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

/// Build `app`'s graph + first scene and render it once through the wandr renderer
/// into `options.sink`. The host is retained for the process lifetime (a guest keeps
/// one host across frames; this also dodges the Subgraph.forEach teardown wall).
/// Call `wandrRedraw()` each subsequent frame to repaint under double-buffering.
@_spi(WandrRenderer)
public func renderWandrAppOnce(
    _ app: some App,
    options: _RendererConfiguration.WandrOptions
) {
    Update.dispatchImmediately(reason: nil) {
        let graph = AppGraph(app: app)
        graph.instantiate()
        AppGraph.shared = graph
        guard let item = graph.rootSceneList?.items.first else {
            return
        }
        let rootView = item.value.view
            .frame(width: options.surface.width, height: options.surface.height)
        let host = WandrRendererHost(
            rootView: rootView,
            environment: item.environment,
            options: options
        )
        _wandrHostKeepAlive = host
        _wandrRedraw = { host.redraw() }
        host.renderOnce()
    }
}

/// Re-walk the current display list into the sink passed to `renderWandrAppOnce`.
/// The guest points the sink's CGContext at the new back-buffer, then calls this.
@_spi(WandrRenderer)
public func wandrRedraw() {
    _wandrRedraw?()
}
#endif
