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

// [wandr] name the DisplayList content/effect kinds this renderer does NOT yet handle, so the
// `default` branches can announce exactly what was dropped (via wandrWarnOnce, once each).
private func wandrContentName(_ c: DisplayList.Content.Value) -> String {
    switch c {
    case .backdrop: return "backdrop"; case .color: return "color"
    case .chameleonColor: return "chameleonColor"; case .image: return "image (bitmap/SF-symbol)"
    case .shape: return "shape"; case .shadow: return "shadow"
    case .platformView: return "platformView"; case .platformLayer: return "platformLayer"
    case .text: return "text"; case .flattened: return "flattened"
    case .drawing: return "drawing (ORB/Canvas)"; case .view: return "view"
    case .placeholder: return "placeholder"; @unknown default: return "unknown"
    }
}
private func wandrEffectName(_ e: DisplayList.Effect) -> String {
    switch e {
    case .archive: return "archive"; case .platformGroup: return "platformGroup"
    case .opacity: return "opacity"; case .blendMode: return "blendMode"
    case .clip: return "clip"; case .mask: return "mask"
    case let .transform(t):
        switch t {
        case .affine: return "transform.affine"; case .projection: return "transform.projection"
        case .rotation: return "transform.rotation"; case .rotation3D: return "transform.rotation3D"
        @unknown default: return "transform.?"
        }
    case .filter: return "filter (blur/shadow)"; case .contentTransition: return "contentTransition"
    case .accessibility: return "accessibility"; case .state: return "state"
    case .interpolatorRoot, .interpolatorLayer, .interpolatorAnimation: return "interpolator"
    case .view: return "view"; case .platform: return "platform"
    case .backdropGroup: return "backdropGroup"; @unknown default: return "unknown"
    }
}

// [wandr] Serialize a Path to SVG path-data (the wasi:canvas clip-path / draw-path grammar),
// mapping each point through `t` (path-local → surface). Used for clip regions (`.clip`) and
// solid-color `.shape` fills so rounded rects / circles / capsules render their real outline.
//
// NOTE: `Path.forEach` is an unimplemented stub off-Apple (traps), so we read `path.storage`
// directly and handle the shapes 2048 actually uses (rect, roundedRect, ellipse). Arbitrary /
// deprecated storage falls back to the bounding rect — a plain-rect clip instead of a trap.
private func wandrSVGPath(_ path: Path, applying t: CGAffineTransform) -> String {
    switch path.storage {
    case .empty:
        return ""
    case let .rect(r):
        return wandrRoundedRectSVG(r, corner: .zero, applying: t)
    case let .roundedRect(rr):
        return wandrRoundedRectSVG(rr.rect, corner: rr.clampedCornerSize, applying: t)
    case let .ellipse(r):
        // An inscribed ellipse == a rounded rect whose corner radii are half the sides.
        return wandrRoundedRectSVG(r, corner: CGSize(width: r.width / 2, height: r.height / 2), applying: t)
    default:
        let b = path.boundingRect
        return wandrRoundedRectSVG(b, corner: .zero, applying: t)
    }
}

// [wandr] SVG for a rect with (possibly zero) uniform corner radii, each point mapped through `t`.
// Arc radii are scaled by the transform's linear magnitude — correct for the translation+scale that
// 2048 applies to clips (rotation would need an x-axis-rotation term, not emitted).
private func wandrRoundedRectSVG(_ rect: CGRect, corner: CGSize, applying t: CGAffineTransform) -> String {
    guard rect.width > 0, rect.height > 0 else { return "" }
    let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
    let cw = min(corner.width, w / 2), ch = min(corner.height, h / 2)
    func P(_ px: CGFloat, _ py: CGFloat) -> CGPoint { CGPoint(x: px, y: py).applying(t) }
    if cw <= 0.01 || ch <= 0.01 {
        let a = P(x, y), b = P(x + w, y), c = P(x + w, y + h), d = P(x, y + h)
        return "M \(a.x) \(a.y) L \(b.x) \(b.y) L \(c.x) \(c.y) L \(d.x) \(d.y) Z"
    }
    let rx = cw * (t.a * t.a + t.b * t.b).squareRoot()
    let ry = ch * (t.c * t.c + t.d * t.d).squareRoot()
    let p = [
        P(x + cw, y), P(x + w - cw, y),
        P(x + w, y + ch), P(x + w, y + h - ch),
        P(x + w - cw, y + h), P(x + cw, y + h),
        P(x, y + h - ch), P(x, y + ch),
    ]
    // Clockwise (SVG y-down ⇒ sweep-flag 1), one 90° arc per corner.
    return "M \(p[0].x) \(p[0].y) "
        + "L \(p[1].x) \(p[1].y) A \(rx) \(ry) 0 0 1 \(p[2].x) \(p[2].y) "
        + "L \(p[3].x) \(p[3].y) A \(rx) \(ry) 0 0 1 \(p[4].x) \(p[4].y) "
        + "L \(p[5].x) \(p[5].y) A \(rx) \(ry) 0 0 1 \(p[6].x) \(p[6].y) "
        + "L \(p[7].x) \(p[7].y) A \(rx) \(ry) 0 0 1 \(p[0].x) \(p[0].y) Z"
}

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
        case let .shape(shapePath, paint, _):
            guard let color = paint.wandrResolvedColor else {
                wandrWarnOnce("render: .shape paint is not a solid color (gradient/material/pattern) — dropped")
                break
            }
            let resolved = color.multiplyingOpacity(by: opacity)
            // The shape's Path is path-local (origin-based, DisplayListViewModel offsets it by the
            // item frame origin). Map local → surface with the linear part of `transform` plus the
            // surface-space frame origin (translation+scale case; rotation is the deferred 3D path).
            let shapeT = CGAffineTransform(
                a: transform.a, b: transform.b, c: transform.c, d: transform.d,
                tx: frame.minX, ty: frame.minY
            )
            let svg = wandrSVGPath(shapePath, applying: shapeT)
            if svg.isEmpty {
                emitFill(frame: frame, color: resolved)   // .empty / degenerate: fall back to bounds
            } else {
                sink.fillPath(
                    svgPath: svg,
                    x: Double(frame.minX), y: Double(frame.minY),
                    width: Double(frame.width), height: Double(frame.height),
                    red: resolved.red, green: resolved.green, blue: resolved.blue,
                    opacity: resolved.opacity
                )
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
            // A resizable symbol (Image(systemName:).resizable()) FILLS its frame: size the icon
            // glyph to the laid-out rect here. The content rule can't do this — reading the
            // resolved size there cycles the AttributeGraph — so the sizing lands at draw time.
            let fill = textView.wasmSymbolFill
            let drawFontSize = fill ? Double(min(frame.width, frame.height)) : Double(textView.wasmFontSize)
            // [wandr] `width` is the host paragraph's maxWidth (governs WRAPPING only; the paint
            // stays left-aligned at `x`). OpenSwiftUI underestimates a word's measured width on wasm
            // (host/Skia renders ~a glyph wider), so a tight box wrapped labels like "SCORE" →
            // "SCOR"/"E". A SINGLE word (no space) has no legal break point and must never split
            // mid-character — e.g. a tile's "16" was breaking to "1"/"6" once the number slightly
            // exceeded the estimated frame (worst when the board shrinks behind the end-game modal).
            // Give single-word text effectively unbounded width so it stays on one line; multi-word
            // text keeps a +20% slack to fix the spurious wrap without letting long prose overflow.
            let isSingleWord = !textView.wasmPlainString.contains(" ")
            let drawWidth = fill
                ? Double(frame.width)
                : (isSingleWord ? Double(frame.width) + 100_000 : Double(frame.width) * 1.2)
            sink.drawText(
                textView.wasmPlainString,
                x: Double(frame.minX), y: Double(frame.minY),
                width: drawWidth, height: Double(frame.height),
                fontSize: drawFontSize,
                red: c?.red ?? 1.0, green: c?.green ?? 1.0, blue: c?.blue ?? 1.0,
                opacity: (c?.opacity ?? 1.0) * opacity,
                fontFamily: textView.wasmFontFamily
            )
        default:
            // TODO: image, shadow, backdrop, view, platform* — grow WandrDrawSink.
            wandrWarnOnce("render: dropped content .\(wandrContentName(content.value))")
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
        case let .transform(.rotation3D(data)):
            wandrApplyProjection(data.transform, list: list, transform: transform, opacity: opacity)
        case let .transform(.projection(projection)):
            wandrApplyProjection(projection, list: list, transform: transform, opacity: opacity)
        case let .clip(clipPath, _, _):
            // The clip Path is local (origin .zero, from _ClipEffect.effectValue); the effect
            // item's frame origin is already folded into `transform` above, so mapping the path
            // through `transform` places the clip in surface space — exactly like content frames.
            let svg = wandrSVGPath(clipPath, applying: transform)
            if svg.isEmpty {
                append(list: list, transform: transform, opacity: opacity)
            } else {
                sink.pushClip(svgPath: svg)
                append(list: list, transform: transform, opacity: opacity)
                sink.popClip()
            }
        case let .filter(.shadow(style)):
            // eleev's cards are `.clipShape(RoundedRectangle).shadow()` — the shadow wraps a clip, so
            // a per-shape shadow would be clipped away. Draw a blurred shadow of the card's SILHOUETTE
            // (the wrapped clip path) BEHIND, then the clipped card on top. No silhouette ⇒ drop.
            if let silhouette = wandrShadowSilhouette(list, transform: transform) {
                let c = style.color
                sink.fillPathShadow(
                    svgPath: silhouette,
                    dx: Double(style.offset.width), dy: Double(style.offset.height),
                    blur: Double(style.radius),
                    red: c.red, green: c.green, blue: c.blue, opacity: c.opacity * opacity
                )
            }
            append(list: list, transform: transform, opacity: opacity)
        default:
            // TODO: clip, mask, blendMode, filter — recurse unmodified for now.
            wandrWarnOnce("render: dropped effect .\(wandrEffectName(effect)) (content still drawn, effect ignored)")
            append(list: list, transform: transform, opacity: opacity)
        }
    }

    // [wandr] Apply a ProjectionTransform (rotation3DEffect / non-affine projection). OpenSwiftUI
    // already computes the matrix (`_Rotation3DEffect.Data.transform`), so no rotation math here.
    // An AFFINE projection folds into the flatten transform. A PERSPECTIVE one needs the canvas
    // CTM: push the accumulated affine + the projection, draw the subtree in LOCAL coords, restore.
    // The ProjectionTransform → wasi:canvas (Skia) 3×3 map is a transpose (verified by the affine
    // case: m00=m11, m01=m21, m02=m31; m10=m12, m11=m22, m12=m32; m20=m13, m21=m23, m22=m33).
    // Sinks that can't do a perspective CTM draw flat (effect dropped, 2D position preserved).
    // [wandr] The silhouette a `.filter(.shadow)` casts: the clip path of a directly-wrapped `.clip`
    // effect (eleev's `.clipShape(RoundedRectangle).shadow()` pattern), in surface coordinates.
    private func wandrShadowSilhouette(_ list: DisplayList, transform: CGAffineTransform) -> String? {
        for item in list.items {
            guard case let .effect(effect, _) = item.value,
                  case let .clip(clipPath, _, _) = effect else { continue }
            let framed = CGAffineTransform(translationX: item.frame.minX, y: item.frame.minY)
                .concatenating(transform)
            let svg = wandrSVGPath(clipPath, applying: framed)
            if !svg.isEmpty { return svg }
        }
        return nil
    }

    private mutating func wandrApplyProjection(
        _ pt: ProjectionTransform,
        list: DisplayList,
        transform: CGAffineTransform,
        opacity: Float
    ) {
        if pt.isAffine {
            let affine = CGAffineTransform(a: pt.m11, b: pt.m12, c: pt.m21, d: pt.m22, tx: pt.m31, ty: pt.m32)
            append(list: list, transform: transform.concatenating(affine), opacity: opacity)
            return
        }
        guard sink.wandrSupportsProjection else {
            append(list: list, transform: transform, opacity: opacity)
            return
        }
        sink.saveState()
        // Skia `concat` post-multiplies ⇒ CTM = affine · projection, so a local point maps
        // surface ← affine ← projection ← local.
        sink.concat(m00: Double(transform.a), m01: Double(transform.c), m02: Double(transform.tx),
                    m10: Double(transform.b), m11: Double(transform.d), m12: Double(transform.ty),
                    m20: 0, m21: 0, m22: 1)
        sink.concat(m00: Double(pt.m11), m01: Double(pt.m21), m02: Double(pt.m31),
                    m10: Double(pt.m12), m11: Double(pt.m22), m12: Double(pt.m32),
                    m20: Double(pt.m13), m21: Double(pt.m23), m22: Double(pt.m33))
        append(list: list, transform: .identity, opacity: opacity)
        sink.restoreState()
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
