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
// [wandr] Pointer/gesture entry point. (phase, x, y, serial) → routes a MouseEvent
// through the host's EventBindingManager so `.onTapGesture` / DragGesture callbacks fire.
nonisolated(unsafe) private var _wandrSendEvent: ((Int, Double, Double, Int) -> Void)?

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
        // Re-render must run inside an update transaction (like the initial render below) so a
        // re-evaluated body that creates new attributes has a current subgraph — otherwise
        // Attribute.init(value:) hits "attempting to create attribute with no subgraph".
        _wandrRender = { Update.dispatchImmediately(reason: nil) { host.renderOnce() } }
        _wandrRenderFrame = { interval in
            var pending = false
            Update.dispatchImmediately(reason: nil) { pending = host.renderFrame(interval: interval) }
            return pending
        }
        _wandrSendEvent = { phase, x, y, serial in
            // Must run inside an update transaction: the gesture pipeline enqueues its
            // action on the Update queue, which only drains when the depth returns to 0.
            Update.dispatchImmediately(reason: nil) {
                let eventPhase: EventPhase
                switch phase {
                case 0: eventPhase = .began   // pointer down
                case 1: eventPhase = .active  // pointer move
                case 2: eventPhase = .ended   // pointer up
                default: eventPhase = .failed // cancel
                }
                let location = CGPoint(x: x, y: y)
                let event = MouseEvent(
                    timestamp: host.currentTimestamp,
                    button: .primary,
                    phase: eventPhase,
                    location: location,
                    globalLocation: location,
                    modifiers: []
                )
                // Use EventID(type:serial:) with an integer serial — NEVER the NSObject
                // EventID.init(_:subtype:) overload, which unsafeBitCasts an existential
                // and corrupts ARC on wasm32-wasip1.
                let id = EventID(type: MouseEvent.self, serial: serial)
                host.eventBindingManager.send([id: event])
            }
        }
        host.renderOnce()
    }
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

/// Feed one raw pointer event into OpenSwiftUI's gesture pipeline.
///
/// - Parameters:
///   - phase: `0` = down (→ `.began`), `1` = move (→ `.active`), `2` = up (→ `.ended`),
///     anything else = cancel (→ `.failed`).
///   - x, y: pointer position in surface (global) coordinates.
///   - serial: a sequence id. Use the SAME serial for a down→move→up stream so the gesture
///     tracks it as one interaction; start a new serial for the next press.
///
/// The host routes the event via hit-testing to the bound view's gesture (e.g.
/// `.onTapGesture`) and that gesture's action fires when the transaction drains.
@_spi(WandrRenderer)
public func wandrSendPointer(phase: Int, x: Double, y: Double, serial: Int) {
    _wandrSendEvent?(phase, x, y, serial)
}

// MARK: - Reactor app registration (eleev's @main App, used VERBATIM)
//
// A wandr guest is a wasip1 REACTOR (-mexec-model=reactor): there is no _start, so the app's
// @main-generated entry (__main_argc_argv) is never auto-called. wandr-runtime's `on-init` invokes
// it explicitly (via @_silgen_name), which runs `App.main()`. But main() must NOT run-to-completion
// or exit — the host keeps the instance alive and drives frames via exported callbacks. So, when the
// wandr reactor is "armed" (wandr-runtime sets this immediately before calling the entry), App.main()
// registers the app HERE and RETURNS; wandr-runtime then builds + drives it on the first real-sized
// frame with its own wasi:canvas-backed sink. Net effect: the app carries only `@main struct App`,
// exactly as on Apple platforms — zero wandr code in the app target.
nonisolated(unsafe) var _wandrReactorArmed = false
nonisolated(unsafe) private var _wandrAppLauncher: ((_RendererConfiguration.WandrOptions) -> Void)?

/// wandr-runtime calls this immediately before invoking the @main entry, so `App.main()` takes the
/// register-and-return path instead of the stdout / run-to-completion one.
@_spi(WandrRenderer)
public func armWandrReactor() { _wandrReactorArmed = true }

/// Store the @main app until wandr-runtime's first sized frame builds its graph. Called from
/// `App.main()`'s reactor branch, capturing the concrete app type (`renderWandrAppOnce` stays generic).
@_spi(WandrRenderer)
public func registerWandrApp(_ app: some App) {
    _wandrAppLauncher = { options in renderWandrAppOnce(app, options: options) }
}

/// Build + render the registered app once. wandr-runtime calls this on the first real-sized frame,
/// supplying its wasi:canvas-backed sink + surface. Returns `false` if no app was registered (e.g.
/// the entry was never called, or the app didn't take the reactor path).
@_spi(WandrRenderer)
@discardableResult
public func launchRegisteredWandrApp(options: _RendererConfiguration.WandrOptions) -> Bool {
    guard let launcher = _wandrAppLauncher else { return false }
    launcher(options)
    return true
}
#endif
