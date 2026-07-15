//
//  WandrSymbolGlyph.swift
//  OpenSwiftUICore
//
//  Non-Apple (Linux / Windows / wasm) implementation of `Image(systemName:)` rendering — the
//  counterpart to Apple's CUICatalog / SFSymbols path (both Darwin-only).
//
//  Off-Apple, `NamedImageProvider.resolve` for a `.system`/`.privateSystem` location (SF Symbols)
//  falls through to `resolveError`, which returns an empty `GraphicsImage` that still carries the
//  symbol name in its `AccessibilityImageLabel` (`.systemSymbol(name)`). Nothing then draws — the
//  symbol is invisible. (A `.bundle` location — `Image("Name")` — instead reads a real PNG from the
//  app's `/assets` preopen and DOES carry real decoded pixels; see `NamedImage.swift`'s
//  `wandrResolveBundleBitmap`.)
//
//  This file is the SOLE off-Apple `Image.Resolved` render path (`ResolvedImage.swift`'s
//  `#if !OPENSWIFTUI_LINK_COREUI` gate in `_makeView` routes EVERY off-Apple image — symbol or real
//  bitmap — through here), so it handles both: a real bitmap is routed straight to `.image`
//  DisplayList content (via `StyledTextContentView.wasmBitmapImage` — see `shape(in:)` in
//  `Text+View.swift`); otherwise it wires the symbol name to `OpenSFSymbols` (the open,
//  cross-platform SF Symbols provider): resolve the SF-Symbol name to an open icon font glyph —
//  `(font-family, codepoint)` — and draw that codepoint through the ordinary text leaf
//  (`StyledTextContentView`) tagged with the font family, which the host resolves by name (Skia
//  `match_family_style` / fontconfig / DirectWrite / `SkFontMgr_New_Android`) and shapes. Every
//  OpenSwiftUI app gets both automatically — no per-app wiring. The name→glyph table + fonts live
//  entirely in `OpenSFSymbols`.

#if !OPENSWIFTUI_LINK_COREUI
import OpenAttributeGraphShims
import OpenCoreGraphicsShims
import OpenSFSymbols

extension Image.Resolved {
    /// Non-Apple render path for a resolved image — the SOLE off-Apple `Image.Resolved` render
    /// path, handling both a real bitmap (routed to `.image` DisplayList content) and a
    /// `.systemSymbol(name)` label (resolved via `OpenSFSymbols` to an open-icon glyph, drawn as a
    /// family-tagged text run). See `WandrSymbolLeaf.value`.
    nonisolated package static func wandrMakeSymbolView(
        view: _GraphValue<Image.Resolved>,
        inputs: _ViewInputs
    ) -> _ViewOutputs {
        let leaf = Attribute(
            WandrSymbolLeaf(
                resolved: view.value,
                environment: inputs.environment
            )
        )
        return StyledTextContentView._makeView(view: _GraphValue(leaf), inputs: inputs)
    }
}

/// Builds the `StyledTextContentView` for a resolved symbol at runtime — the glyph codepoint, its
/// icon font family, colour (the environment foreground, as Text resolves it) and size (derived to
/// fill the laid-out frame so `.resizable().scaledToFit()` behaves like a real symbol).
private struct WandrSymbolLeaf: Rule, AsyncAttribute {
    @Attribute var resolved: Image.Resolved
    @Attribute var environment: EnvironmentValues

    // OpenSFSymbols is cheap to construct (its name universe + mapping are parsed once, statically).
    private static let symbols = OpenSFSymbols()

    var value: StyledTextContentView {
        let env = environment
        // [wandr] A real decoded bitmap (task 114 named-image loading, NamedImage.swift's
        // wandrResolveBundleBitmap) takes priority: this is the SOLE off-Apple Image.Resolved render
        // path (see ResolvedImage.swift), so a bundle image with real pixels must be routed to real
        // .image DisplayList content here, not the symbol-glyph text fallback below.
        if case .cgImage = resolved.image.contents {
            // `resizingInfo != nil` means `.resizable()` was applied (see also
            // Image.Resolved.frame(in:), which uses the same check to decide "fill the given size"
            // vs "intrinsic size") — reuse `wasmSymbolFill`'s existing "fill proposed frame" meaning
            // for a resizable bitmap too, matching real SwiftUI Image sizing.
            return StyledTextContentView(
                text: WandrSymbolLeaf.placeholderText,
                wasmSymbolFill: resolved.image.resizingInfo != nil,
                wasmBitmapImage: resolved.image
            )
        }
        var plain = ""
        var family = ""
        if case let .systemSymbol(name)? = resolved.label {
            if let ref = WandrSymbolLeaf.symbols.iconRef(for: name),
               let scalar = Unicode.Scalar(ref.codepoint) {
                plain = String(scalar)
                family = ref.fontFamily
            } else {
                wandrWarnOnce("render: SF-Symbol '\(name)' unresolved by OpenSFSymbols — add it to OpenSFSymbols/Data/overrides.json")
            }
        }
        // Seed the glyph size from the environment font — a non-resizable symbol scales with the
        // font, exactly like inline text. A resizable symbol (`.resizable()`) instead FILLS its
        // proposed frame and the renderer sizes the glyph to the laid-out rect at draw time.
        // NEVER read the resolved ViewSize here: the leaf's own size depends on it, so reading it
        // back into the content rule forms an AttributeGraph layout cycle (the frame-0 crash).
        let pointSize = env.font?.resolveTraits(in: env).pointSize ?? 0
        let fontSize: CGFloat = pointSize > 0 ? pointSize : 17
        let isResizable = resolved.image.resizingInfo != nil
        return StyledTextContentView(
            text: WandrSymbolLeaf.placeholderText,
            wasmPlainString: plain,
            wasmFontSize: fontSize,
            wasmColor: env.foregroundColor?.resolve(in: env),
            wasmFontFamily: family,
            wasmSymbolFill: isResizable
        )
    }

    // A resolved image glyph has no attributed-string storage; the host-shaped-text leaf only reads
    // the wasm* fields, so an empty ResolvedStyledText placeholder satisfies the `text` field.
    private static let placeholderText = ResolvedStyledText(
        storage: nil,
        layoutProperties: .init(),
        layoutMargins: nil,
        stylePadding: .zero,
        archiveOptions: .init(),
        isCollapsible: false,
        features: [],
        suffix: .none,
        attachments: .init(),
        styles: [],
        transitions: [],
        scaleFactorOverride: nil
    )
}
#endif
