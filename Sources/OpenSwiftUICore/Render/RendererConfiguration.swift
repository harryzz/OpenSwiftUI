//
//  RendererConfiguration.swift
//  OpenSwiftUICore
//
//  Audited for 6.5.4
//  Status: Complete

public import Foundation

// MARK: - _RendererConfiguration

/// Renderer configuration for a hosting view.
@available(OpenSwiftUI_v2_0, *)
public struct _RendererConfiguration {

    /// The available renderer kind and their configuration.
    public enum Renderer {
        /// The default renderer for the current platform.
        case `default`

        /// An alternative renderer that rasterizes everything in the
        /// local process.
        indirect case rasterized(_ options: _RendererConfiguration.RasterizationOptions = .init())

        /* OpenSwiftUI Addition Begin */
        #if !OPENSWIFTUI_SWIFTUI_RENDERER
        /// A renderer that writes a textual representation of the display list
        /// to standard output.
        @_spi(StdoutRenderer)
        indirect case stdout(_ options: _RendererConfiguration.StdoutOptions = .init())

        /// A renderer that walks the resolved display list and pushes primitive
        /// draw commands into a `WandrDrawSink` (the wandr Option-B backend: the
        /// guest implements the sink over a wasi:canvas CGContext). No default —
        /// the sink is required.
        indirect case wandr(_ options: _RendererConfiguration.WandrOptions)
        #endif
        /* OpenSwiftUI Addition End */
    }

    /// The renderer kind and its specific configuration.
    public var renderer: _RendererConfiguration.Renderer

    /// The minimum time between display updates. Zero means to attempt
    /// to match the natural display update rate, infinity means to
    /// disable animations, values in between clamp the delay between
    /// animation updates.
    public var minFrameInterval: Double

    public init(renderer: _RendererConfiguration.Renderer = .default) {
        self.renderer = renderer
        self.minFrameInterval = .zero
    }

    /// Returns a configuration to render as a rasterized bitmap.
    public static func rasterized(_ options: _RendererConfiguration.RasterizationOptions = .init()) -> _RendererConfiguration {
        _RendererConfiguration(renderer: .rasterized(options))
    }

    /* OpenSwiftUI Addition Begin */

    #if !OPENSWIFTUI_SWIFTUI_RENDERER
    /// Returns a configuration to render the display list to standard output.
    @_spi(StdoutRenderer)
    public static func stdout(_ options: _RendererConfiguration.StdoutOptions = .init()) -> _RendererConfiguration {
        _RendererConfiguration(renderer: .stdout(options))
    }

    /// Returns a configuration that renders the display list into a `WandrDrawSink`.
    public static func wandr(_ options: _RendererConfiguration.WandrOptions) -> _RendererConfiguration {
        _RendererConfiguration(renderer: .wandr(options))
    }
    #endif

    /* OpenSwiftUI Addition End */

    /* OpenSwiftUI Addition Begin */

    // MARK: - _RendererConfiguration.StdoutOptions

    /// Options for the `stdout` renderer.
    @_spi(StdoutRenderer)
    public struct StdoutOptions {
        /// The surface size reported by the stdout renderer.
        public var surface: CGSize = defaultSurfaceSize

        // TODO: Get from host platform API
        private static let defaultSurfaceSize = CGSize(width: 640.0, height: 480.0)

        public init() {}
    }

    // MARK: - _RendererConfiguration.WandrOptions

    /// Options for the `wandr` renderer.
    public struct WandrOptions {
        /// The surface size the display list is laid out / rendered into.
        public var surface: CGSize = CGSize(width: 640.0, height: 480.0)

        /// The sink that receives resolved primitive draw commands.
        public var sink: WandrDrawSink

        public init(surface: CGSize = CGSize(width: 640.0, height: 480.0), sink: WandrDrawSink) {
            self.surface = surface
            self.sink = sink
        }
    }

    /* OpenSwiftUI Addition End */

    // MARK: - _RendererConfiguration.RasterizationOptions

    /// Options for the `rasterized` renderer.
    public struct RasterizationOptions {

        /// The color mode to use when rendering the view.
        public var colorMode: ColorRenderingMode = .nonLinear

        /// When non-nil overrides colorMode with a member of the
        /// `RBColorMode` enum, specified as its raw integer value.
        public var rbColorMode: Int32?

        /// When true the view will build and submit its command buffer
        /// asynchronously.
        public var rendersAsynchronously: Bool = false

        /// When true no alpha component is created for the view’s
        /// content. Setting this value will often require less memory.
        public var isOpaque: Bool = true

        /// When true native platform views that have been inserted
        /// into the view hierarchy (e.g. via UIViewRepresentable) will
        /// be drawn via their CALayer’s -renderInContext: method
        /// (after updating their view bounds).
        public var drawsPlatformViews: Bool = true

        /// Set this to true to avoid using buffer formats that would
        /// disable display compositing; doing so may increase memory
        /// requirements.
        public var prefersDisplayCompositing: Bool = false

        /// The maximum number of surfaces that will be allocated by
        /// the view, will currently be clamped to the range [2, 3].
        public var maxDrawableCount: Int = 3

        public init() {
            _openSwiftUIEmptyStub()
        }
    }
}

@available(*, unavailable)
extension _RendererConfiguration: Sendable {}

@available(*, unavailable)
extension _RendererConfiguration.Renderer: Sendable {}

@available(*, unavailable)
extension _RendererConfiguration.RasterizationOptions: Sendable {}

/* OpenSwiftUI Addition Begin */
@_spi(StdoutRenderer)
@available(*, unavailable)
extension _RendererConfiguration.StdoutOptions: Sendable {}

@available(*, unavailable)
extension _RendererConfiguration.WandrOptions: Sendable {}

// MARK: - WandrDrawSink

/// The drawing sink for the `wandr` renderer (Option B). OpenSwiftUI walks the
/// resolved `DisplayList` and pushes primitive, fully-resolved draw commands here;
/// the wandr guest implements this over a wasi:canvas `CGContext`. Coordinates are
/// in surface space (top-left origin); colors are sRGB 0...1 with premultiplied
/// opacity already folded into `opacity`. Geometry/colors are plain scalars so the
/// sink stays independent of any CoreGraphics type.
public protocol WandrDrawSink: AnyObject {
    /// Called once at the start of a render pass with the surface size + display-list version.
    func beginFrame(width: Double, height: Double, version: UInt32)

    /// Fill an axis-aligned rectangle (resolved from `.content(.color)` / `.shape`-with-solid-paint).
    func fillRect(
        x: Double, y: Double, width: Double, height: Double,
        red: Float, green: Float, blue: Float, opacity: Float
    )

    /// Draw `text` within the given frame (from `.content(.text)`). The HOST does shaping +
    /// paragraph layout (wasi:canvas paragraph / Skia); the guest passes the plain string,
    /// the laid-out frame, the nominal font size, and the sRGB color.
    func drawText(
        _ text: String,
        x: Double, y: Double, width: Double, height: Double,
        fontSize: Double, red: Float, green: Float, blue: Float, opacity: Float,
        fontFamily: String
    )

    /// Called once at the end of a render pass.
    func endFrame()
}
/* OpenSwiftUI Addition End */

// MARK: - RasterizationOptions + _RendererConfiguration.RasterizationOptions

extension RasterizationOptions {

    /// Convert from the public `_RendererConfiguration.RasterizationOptions`
    /// to the internal `RasterizationOptions`.
    package init(_ options: _RendererConfiguration.RasterizationOptions) {
        var flags: RasterizationOptions.Flags = .defaultFlags
        flags.formUnion(.isAccelerated)
        if options.isOpaque {
            flags.formUnion(.isOpaque)
        } else {
            flags.subtract([.isOpaque, .rendersAsynchronously, .prefersDisplayCompositing])
        }
        if options.rendersAsynchronously {
            flags.formUnion(.rendersAsynchronously)
        }
        if options.prefersDisplayCompositing {
            flags.formUnion(.prefersDisplayCompositing)
        }
        self.init(
            colorMode: options.colorMode,
            rbColorMode: options.rbColorMode,
            flags: flags,
            maxDrawableCount: Int8(truncatingIfNeeded: options.maxDrawableCount)
        )
    }
}

// MARK: - _RenderingCapabilities

/// Platform/renderer capabilities queried by core view logic INSTEAD of compile-time
/// `#if os(WASI)`/`#if os(Linux)`. Core stays platform-agnostic and compiles unmodified on every
/// platform; the WASI-vs-Linux-vs-Apple decision lives in the platform/renderer layer, which
/// overrides these (e.g. the wandr wasi:canvas renderer in renderWandrAppOnce). Defaults are the
/// Apple/CoreGraphics behavior, so unconfigured (Apple) builds are unaffected.
package struct _RenderingCapabilities: Sendable {
    /// Whether view transitions (insert/remove animations via `ViewListContentTransition`) are
    /// available. When `false`, dynamic-container items carrying a `.transition` render directly.
    package var supportsViewTransitions: Bool

    /// Whether `Text` renders as a host-shaped `.content(.text)` display-list leaf (the renderer
    /// shapes the glyphs) rather than the in-framework ShapeStyle glyph-layer path.
    package var usesHostShapedText: Bool

    package init(supportsViewTransitions: Bool = true, usesHostShapedText: Bool = false) {
        self.supportsViewTransitions = supportsViewTransitions
        self.usesHostShapedText = usesHostShapedText
    }

    /// Active capabilities; set once by the platform/renderer layer before rendering
    /// (single-threaded on WASI). Apple builds use the defaults.
    package nonisolated(unsafe) static var current = _RenderingCapabilities()
}
