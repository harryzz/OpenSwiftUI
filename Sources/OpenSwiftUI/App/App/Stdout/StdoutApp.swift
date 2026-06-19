//
//  StdoutApp.swift
//  OpenSwiftUI

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
@_spi(StdoutRenderer)
import OpenSwiftUICore

// MARK: - runStdoutApp

func runStdoutApp(
    _ app: some App,
    options: _RendererConfiguration.StdoutOptions
) -> Never {
    Update.dispatchImmediately(reason: nil) {
        let graph = AppGraph(app: app)
        graph.instantiate()
        AppGraph.shared = graph
        guard let item = graph.rootSceneList?.items.first else {
            print("OpenSwiftUI stdout renderer: no scene to render")
            return
        }
        #if os(macOS) || os(iOS) || os(visionOS)
        let rootView = item.value.view
            .frame(width: options.surface.width, height: options.surface.height)
            .rootEnvironment(scenePhase: .active, sceneID: item.id)
        #else
        let rootView = item.value.view
            .frame(width: options.surface.width, height: options.surface.height)
        #endif
        let host = StdoutRendererHost(
            rootView: rootView,
            environment: item.environment,
            options: options
        )
        host.renderOnce()
        #if os(WASI)
        // WASI: exit BEFORE the closure's locals (host/graph) deinit. Teardown runs
        // GraphHost.invalidate -> Subgraph.forEach, an arg-closure that still hits the
        // swiftcall mislowering; for a one-shot stdout render we don't need clean
        // teardown. exit(0) also flushes stdout. (Remove once forEach has a *C variant.)
        exit(0)
        #endif
    }
    exit(0)
}
#endif
