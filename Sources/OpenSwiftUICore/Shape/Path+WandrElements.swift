//
//  Path+WandrElements.swift
//  OpenSwiftUICore
//
//  [wandr] Pure-Swift custom-Path support for platforms without a real CoreGraphics/ORBPath (WASI).
//
//  Upstream OpenSwiftUI backs Path by ORBPath (OpenRenderBox) / CGPath, both of which are
//  unimplemented off-Apple — so the whole mutable element API (move/addLine/addArc/…), `forEach`
//  and `strokedPath` trap. Built-in shapes (Rectangle/RoundedRectangle/Circle/…) render because the
//  wandr renderer reads `Path.storage` directly (see WandrDisplayListRenderer.wandrSVGPath); custom
//  shapes that build a path element-by-element (e.g. a `Pie`) had no working representation.
//
//  This adds a `Path.Storage.wandrElements([Element])` case (a plain Swift element buffer) plus the
//  geometry to build it (arcs flattened to cubic Béziers), walk it (`forEach`), stroke it
//  (`strokedPath`, as a fillable outline since the renderer only fills), and measure it. The renderer
//  serializes the buffer to SVG path-data. Arcs/ellipses/rounded corners are cubic-Bézier
//  approximations (kappa = 0.5522847498), which is what SVG/Skia want anyway.
#if !canImport(CoreGraphics)
import Foundation
package import OpenCoreGraphicsShims

// CGFloat trig via Double (off-Apple `cos`/`sin`/`tan` only have Double overloads).
private func _wcos(_ a: CGFloat) -> CGFloat { CGFloat(cos(Double(a))) }
private func _wsin(_ a: CGFloat) -> CGFloat { CGFloat(sin(Double(a))) }
private func _wtan(_ a: CGFloat) -> CGFloat { CGFloat(tan(Double(a))) }

extension Path {
    // MARK: storage <-> element buffer

    /// The path expressed as a flat list of drawing elements. Built-in storage cases are converted
    /// on demand so `forEach`/stroke/append work uniformly regardless of how the path was created.
    var wandrElementList: [Element] {
        switch storage {
        case .empty:
            return []
        case let .rect(r):
            return Path.wandrRectElements(r)
        case let .ellipse(r):
            return Path.wandrEllipseElements(in: r)
        case let .roundedRect(rr):
            return Path.wandrRoundedRectElements(rr.rect, cornerSize: rr.clampedCornerSize)
        case let .wandrElements(elements):
            return elements
        default:
            return []
        }
    }

    /// Append drawing elements, promoting the storage to the element buffer (flattening any built-in
    /// storage first so `Path(rect:).addLine(...)` keeps the rect).
    mutating func wandrAppend(_ elements: [Element]) {
        guard !elements.isEmpty else { return }
        var list = wandrElementList
        list.append(contentsOf: elements)
        storage = .wandrElements(list)
    }

    /// The last on-path point (ignoring control points) — CoreGraphics' "current point".
    var wandrLastPoint: CGPoint? {
        for element in wandrElementList.reversed() {
            switch element {
            case let .move(to: p), let .line(to: p): return p
            case let .quadCurve(to: p, control: _): return p
            case let .curve(to: p, control1: _, control2: _): return p
            case .closeSubpath: continue
            }
        }
        return nil
    }

    // MARK: element builders (untransformed, then optionally mapped through a transform)

    static func wandrApply(_ p: CGPoint, _ t: CGAffineTransform) -> CGPoint {
        CGPoint(x: t.a * p.x + t.c * p.y + t.tx, y: t.b * p.x + t.d * p.y + t.ty)
    }

    static func wandrTransform(_ elements: [Element], _ t: CGAffineTransform) -> [Element] {
        guard t != .identity else { return elements }
        return elements.map { (element: Element) -> Element in
            switch element {
            case let .move(to: p): return Element.move(to: wandrApply(p, t))
            case let .line(to: p): return Element.line(to: wandrApply(p, t))
            case let .quadCurve(to: p, control: c): return Element.quadCurve(to: wandrApply(p, t), control: wandrApply(c, t))
            case let .curve(to: p, control1: c1, control2: c2): return Element.curve(to: wandrApply(p, t), control1: wandrApply(c1, t), control2: wandrApply(c2, t))
            case .closeSubpath: return Element.closeSubpath
            }
        }
    }

    static func wandrRectElements(_ r: CGRect) -> [Element] {
        [
            .move(to: CGPoint(x: r.minX, y: r.minY)),
            .line(to: CGPoint(x: r.maxX, y: r.minY)),
            .line(to: CGPoint(x: r.maxX, y: r.maxY)),
            .line(to: CGPoint(x: r.minX, y: r.maxY)),
            .closeSubpath,
        ]
    }

    private static let wandrKappa: CGFloat = 0.5522847498307936

    static func wandrEllipseElements(in rect: CGRect) -> [Element] {
        let rx = rect.width / 2, ry = rect.height / 2
        let cx = rect.midX, cy = rect.midY
        let kx = rx * wandrKappa, ky = ry * wandrKappa
        return [
            .move(to: CGPoint(x: cx + rx, y: cy)),
            .curve(to: CGPoint(x: cx, y: cy + ry), control1: CGPoint(x: cx + rx, y: cy + ky), control2: CGPoint(x: cx + kx, y: cy + ry)),
            .curve(to: CGPoint(x: cx - rx, y: cy), control1: CGPoint(x: cx - kx, y: cy + ry), control2: CGPoint(x: cx - rx, y: cy + ky)),
            .curve(to: CGPoint(x: cx, y: cy - ry), control1: CGPoint(x: cx - rx, y: cy - ky), control2: CGPoint(x: cx - kx, y: cy - ry)),
            .curve(to: CGPoint(x: cx + rx, y: cy), control1: CGPoint(x: cx + kx, y: cy - ry), control2: CGPoint(x: cx + rx, y: cy - ky)),
            .closeSubpath,
        ]
    }

    static func wandrRoundedRectElements(_ rect: CGRect, cornerSize: CGSize) -> [Element] {
        let cw = min(cornerSize.width, rect.width / 2)
        let ch = min(cornerSize.height, rect.height / 2)
        guard cw > 0.01, ch > 0.01 else { return wandrRectElements(rect) }
        let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
        let kx = cw * wandrKappa, ky = ch * wandrKappa
        return [
            .move(to: CGPoint(x: x + cw, y: y)),
            .line(to: CGPoint(x: x + w - cw, y: y)),
            .curve(to: CGPoint(x: x + w, y: y + ch), control1: CGPoint(x: x + w - cw + kx, y: y), control2: CGPoint(x: x + w, y: y + ch - ky)),
            .line(to: CGPoint(x: x + w, y: y + h - ch)),
            .curve(to: CGPoint(x: x + w - cw, y: y + h), control1: CGPoint(x: x + w, y: y + h - ch + ky), control2: CGPoint(x: x + w - cw + kx, y: y + h)),
            .line(to: CGPoint(x: x + cw, y: y + h)),
            .curve(to: CGPoint(x: x, y: y + h - ch), control1: CGPoint(x: x + cw - kx, y: y + h), control2: CGPoint(x: x, y: y + h - ch + ky)),
            .line(to: CGPoint(x: x, y: y + ch)),
            .curve(to: CGPoint(x: x + cw, y: y), control1: CGPoint(x: x, y: y + ch - ky), control2: CGPoint(x: x + cw - kx, y: y)),
            .closeSubpath,
        ]
    }

    /// Circular arc as a sequence of cubic Béziers (≤90° each), NOT including a leading move — the
    /// caller's current point is joined to the arc start with an implicit line (CoreGraphics
    /// semantics). `from` is the current point, if any.
    static func wandrArcElements(center c: CGPoint, radius r: CGFloat, start a0: CGFloat, end a1: CGFloat, clockwise: Bool, from: CGPoint?) -> [Element] {
        var start = a0
        var end = a1
        if clockwise {
            while end > start { end -= 2 * .pi }
        } else {
            while end < start { end += 2 * .pi }
        }
        let sweep = end - start
        let segments = max(1, Int((abs(sweep) / (.pi / 2)).rounded(.up)))
        let delta = sweep / CGFloat(segments)
        func point(_ angle: CGFloat) -> CGPoint { CGPoint(x: c.x + r * _wcos(angle), y: c.y + r * _wsin(angle)) }
        var result: [Element] = []
        let arcStart = point(start)
        // CoreGraphics adds a line from the current point to the arc start (a move if there is none).
        if let from {
            if abs(from.x - arcStart.x) > 0.001 || abs(from.y - arcStart.y) > 0.001 {
                result.append(.line(to: arcStart))
            }
        } else {
            result.append(.move(to: arcStart))
        }
        var theta = start
        for _ in 0 ..< segments {
            let t0 = theta, t1 = theta + delta
            let k = (4.0 / 3.0) * _wtan((t1 - t0) / 4)
            let p0 = point(t0), p3 = point(t1)
            let c1 = CGPoint(x: p0.x - k * r * _wsin(t0), y: p0.y + k * r * _wcos(t0))
            let c2 = CGPoint(x: p3.x + k * r * _wsin(t1), y: p3.y - k * r * _wcos(t1))
            result.append(.curve(to: p3, control1: c1, control2: c2))
            theta = t1
        }
        return result
    }

    // MARK: measurement + iteration

    static func wandrBounds(_ elements: [Element]) -> CGRect {
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        func include(_ p: CGPoint) {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        for element in elements {
            switch element {
            case let .move(to: p), let .line(to: p): include(p)
            case let .quadCurve(to: p, control: c): include(p); include(c)
            case let .curve(to: p, control1: c1, control2: c2): include(p); include(c1); include(c2)
            case .closeSubpath: break
            }
        }
        guard minX <= maxX else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: stroking (outline as a fillable region, since the renderer only fills)

    private static func wandrQuad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let mt = 1 - t
        return CGPoint(x: mt * mt * a.x + 2 * mt * t * c.x + t * t * b.x,
                       y: mt * mt * a.y + 2 * mt * t * c.y + t * t * b.y)
    }

    private static func wandrCubic(_ a: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let mt = 1 - t
        let w0 = mt * mt * mt, w1 = 3 * mt * mt * t, w2 = 3 * mt * t * t, w3 = t * t * t
        return CGPoint(x: w0 * a.x + w1 * c1.x + w2 * c2.x + w3 * b.x,
                       y: w0 * a.y + w1 * c1.y + w2 * c2.y + w3 * b.y)
    }

    /// Flatten to polylines (one per subpath) with a closed flag, subdividing curves.
    static func wandrFlatten(_ elements: [Element]) -> [(points: [CGPoint], closed: Bool)] {
        var subpaths: [(points: [CGPoint], closed: Bool)] = []
        var current: [CGPoint] = []
        var start = CGPoint.zero
        func flushOpen() {
            if current.count > 1 { subpaths.append((current, false)) }
            current = []
        }
        let steps = 12
        for element in elements {
            switch element {
            case let .move(to: p):
                flushOpen(); current = [p]; start = p
            case let .line(to: p):
                if current.isEmpty { current = [start] }
                current.append(p)
            case let .quadCurve(to: p, control: c):
                let p0 = current.last ?? start
                if current.isEmpty { current = [p0] }
                for i in 1 ... steps { current.append(wandrQuad(p0, c, p, CGFloat(i) / CGFloat(steps))) }
            case let .curve(to: p, control1: c1, control2: c2):
                let p0 = current.last ?? start
                if current.isEmpty { current = [p0] }
                for i in 1 ... steps { current.append(wandrCubic(p0, c1, c2, p, CGFloat(i) / CGFloat(steps))) }
            case .closeSubpath:
                if current.count > 1 { subpaths.append((current, true)) }
                current = []
            }
        }
        flushOpen()
        return subpaths
    }

    /// Build a fillable outline of the stroked path (per-segment quads plus square joins). An
    /// approximation — no miter/round-join geometry — but visually correct for thin borders, which
    /// is all the fill-only renderer can consume.
    static func wandrStrokeOutline(_ elements: [Element], width: CGFloat) -> [Element] {
        guard width > 0 else { return [] }
        let hw = width / 2
        var out: [Element] = []
        for (points, closed) in wandrFlatten(elements) {
            var poly = points
            if closed, let first = points.first { poly.append(first) }
            guard poly.count >= 2 else { continue }
            for i in 0 ..< (poly.count - 1) {
                let a = poly[i], b = poly[i + 1]
                let dx = b.x - a.x, dy = b.y - a.y
                let len = (dx * dx + dy * dy).squareRoot()
                guard len > 0.0001 else { continue }
                let nx = -dy / len * hw, ny = dx / len * hw
                out.append(.move(to: CGPoint(x: a.x + nx, y: a.y + ny)))
                out.append(.line(to: CGPoint(x: b.x + nx, y: b.y + ny)))
                out.append(.line(to: CGPoint(x: b.x - nx, y: b.y - ny)))
                out.append(.line(to: CGPoint(x: a.x - nx, y: a.y - ny)))
                out.append(.closeSubpath)
            }
            // Fill the gaps at each join/cap with a small square.
            for p in poly {
                out.append(.move(to: CGPoint(x: p.x - hw, y: p.y - hw)))
                out.append(.line(to: CGPoint(x: p.x + hw, y: p.y - hw)))
                out.append(.line(to: CGPoint(x: p.x + hw, y: p.y + hw)))
                out.append(.line(to: CGPoint(x: p.x - hw, y: p.y + hw)))
                out.append(.closeSubpath)
            }
        }
        return out
    }
}
#endif
