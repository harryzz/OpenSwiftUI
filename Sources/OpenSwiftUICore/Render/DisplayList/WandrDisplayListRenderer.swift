//
//  WandrDisplayListRenderer.swift
//  OpenSwiftUICore
//
//  The wandr Option-B rendering backend: walk the resolved DisplayList and push
//  primitive draw commands into a WandrDrawSink (the guest implements the sink over
//  a wasi:canvas CGContext → skia/EGL). Parallel to the stdout renderer
//  (DisplayListStdoutRenderer) — same recursive resolution (opacity multiply,
//  affine transform, shape→solid-color), but emitting to a sink instead of text.
//
//  Status: WIP — colors + solid shapes + opacity/transform resolved today; clip,
//  text, images, masks are TODO (the sink protocol grows additively).

#if !OPENSWIFTUI_SWIFTUI_RENDERER
package import Foundation
package import OpenCoreGraphicsShims

// MARK: - DisplayList + wandr sink rendering

extension DisplayList {
    package func renderToWandrSink(
        _ sink: WandrDrawSink,
        surface: CGSize,
        version: DisplayList.Version
    ) {
        sink.beginFrame(
            width: Double(surface.width),
            height: Double(surface.height),
            version: UInt32(truncatingIfNeeded: version.value)
        )
        var visitor = WandrSinkVisitor(sink: sink)
        visitor.append(list: self)
        sink.endFrame()
    }
}

private struct WandrSinkVisitor {
    let sink: WandrDrawSink

    mutating func append(
        list: DisplayList,
        transform: CGAffineTransform = .identity,
        opacity: Float = 1.0
    ) {
        for item in list.items {
            append(item: item, transform: transform, opacity: opacity)
        }
    }

    private mutating func append(
        item: DisplayList.Item,
        transform: CGAffineTransform,
        opacity: Float
    ) {
        switch item.value {
        case let .content(content):
            append(
                content: content,
                frame: item.frame.applying(transform),
                transform: transform,
                opacity: opacity
            )
        case let .effect(effect, list):
            // The effect item's frame.origin positions its content within the parent — the
            // layout offset (rows/columns/sub-view placement) lives here, exactly as it does
            // in a .content item's frame. Fold it into the transform before applying the
            // effect, else nested/dynamic content (ForEach, stacks) collapses to the origin.
            let framed = CGAffineTransform(translationX: item.frame.minX, y: item.frame.minY)
                .concatenating(transform)
            append(effect: effect, list: list, transform: framed, opacity: opacity)
        case let .states(states):
            for (_, list) in states {
                append(list: list, transform: transform, opacity: opacity)
            }
        case .empty:
            break
        }
    }

    private mutating func emitFill(frame: CGRect, color: Color.Resolved) {
        sink.fillRect(
            x: Double(frame.minX), y: Double(frame.minY),
            width: Double(frame.width), height: Double(frame.height),
            red: color.red, green: color.green, blue: color.blue, opacity: color.opacity
        )
    }

    private mutating func append(
        content: DisplayList.Content,
        frame: CGRect,
        transform: CGAffineTransform,
        opacity: Float
    ) {
        switch content.value {
        case let .color(color):
            emitFill(frame: frame, color: color.multiplyingOpacity(by: opacity))
        case let .shape(_, paint, _):
            if let color = paint.wandrResolvedColor {
                emitFill(frame: frame, color: color.multiplyingOpacity(by: opacity))
            }
        case let .flattened(list, offset, _):
            append(
                list: list,
                transform: transform.concatenating(
                    CGAffineTransform(translationX: frame.minX + offset.x, y: frame.minY + offset.y)
                ),
                opacity: opacity
            )
        case let .text(textView, _):
            // The laid-out `frame` positions the text; the host shapes + draws the string.
            // Color is the environment-resolved foreground (white fallback when unset);
            // opacity carries the accumulated effect opacity.
            let c = textView.wasmColor
            sink.drawText(
                textView.wasmPlainString,
                x: Double(frame.minX), y: Double(frame.minY),
                width: Double(frame.width), height: Double(frame.height),
                fontSize: Double(textView.wasmFontSize),
                red: c?.red ?? 1.0, green: c?.green ?? 1.0, blue: c?.blue ?? 1.0,
                opacity: (c?.opacity ?? 1.0) * opacity
            )
        default:
            // TODO: image, shadow, backdrop, view, platform* — grow WandrDrawSink.
            break
        }
    }

    private mutating func append(
        effect: DisplayList.Effect,
        list: DisplayList,
        transform: CGAffineTransform,
        opacity: Float
    ) {
        switch effect {
        case let .opacity(alpha):
            append(list: list, transform: transform, opacity: opacity * alpha)
        case let .transform(.affine(affine)):
            append(list: list, transform: transform.concatenating(affine), opacity: opacity)
        default:
            // TODO: clip, mask, blendMode, filter — recurse unmodified for now.
            append(list: list, transform: transform, opacity: opacity)
        }
    }
}

private struct WandrColorPaintVisitor: ResolvedPaintVisitor {
    var color: Color.Resolved?

    mutating func visitPaint<P>(_ paint: P) where P: ResolvedPaint {
        color = paint as? Color.Resolved
    }
}

private extension AnyResolvedPaint {
    var wandrResolvedColor: Color.Resolved? {
        var visitor = WandrColorPaintVisitor()
        visit(&visitor)
        return visitor.color
    }
}

// MARK: - WandrDisplayListRenderer

final class WandrDisplayListRenderer: ViewRendererBase {
    let platform: DisplayList.ViewUpdater.Platform
    weak var host: (any ViewRendererHost)?
    var options: _RendererConfiguration.WandrOptions
    private var seed: DisplayList.Seed = .init()
    private var hasRendered = false

    init(
        platform: DisplayList.ViewUpdater.Platform,
        host: (any ViewRendererHost)?,
        options: _RendererConfiguration.WandrOptions
    ) {
        self.platform = platform
        self.host = host
        self.options = options
    }

    var exportedObject: AnyObject? { nil }

    func render(
        rootView: AnyObject,
        from list: DisplayList,
        time: Time,
        version: DisplayList.Version,
        maxVersion: DisplayList.Version,
        environment: DisplayList.ViewRenderer.Environment
    ) -> Time {
        let nextSeed = DisplayList.Seed(version)
        guard !hasRendered || nextSeed != seed else {
            return .infinity
        }
        hasRendered = true
        seed = nextSeed
        list.renderToWandrSink(options.sink, surface: options.surface, version: version)
        if let host, let observer = host.as(ViewGraphRenderObserver.self) {
            observer.didRender()
        }
        return .infinity
    }

    func renderAsync(
        to list: DisplayList,
        time: Time,
        targetTimestamp: Time?,
        version: DisplayList.Version,
        maxVersion: DisplayList.Version
    ) -> Time? {
        nil
    }

    func destroy(rootView: AnyObject) {}

    var viewCacheIsEmpty: Bool { true }
}
#endif
