//
//  WandrSymbolGlyph.swift
//  OpenSwiftUICore
//
//  Non-Apple (Linux / Windows / wasm) implementation of `Image(systemName:)` rendering — the
//  counterpart to Apple's CUICatalog / SFSymbols path (both Darwin-only).
//
//  Off-Apple, `NamedImageProvider.resolve` falls through to `resolveError`, which returns an empty
//  `GraphicsImage` that still carries the symbol name in its `AccessibilityImageLabel`
//  (`.systemSymbol(name)`). Nothing then draws — the symbol is invisible.
//
//  This file wires the non-Apple path directly to `OpenSFSymbols` (the open, cross-platform SF
//  Symbols provider): it resolves the SF-Symbol name to an open icon font glyph — `(font-family,
//  codepoint)` — and draws that codepoint through the ordinary text leaf (`StyledTextContentView`)
//  tagged with the font family, which the host resolves by name (Skia `match_family_style` /
//  fontconfig / DirectWrite / `SkFontMgr_New_Android`) and shapes. Every OpenSwiftUI app gets this
//  automatically — no per-app wiring. Reached from one `#if !OPENSWIFTUI_LINK_COREUI` line in
//  `Image.Resolved._makeView`. The name→glyph table + fonts live entirely in `OpenSFSymbols`.

#if !OPENSWIFTUI_LINK_COREUI
import OpenAttributeGraphShims
import OpenCoreGraphicsShims
import OpenSFSymbols

extension Image.Resolved {
    /// Non-Apple render path for a resolved image. Off-Apple no resolved image carries pixels, so
    /// this is the only content source: a `.systemSymbol(name)` label resolved via `OpenSFSymbols`
    /// to an open-icon glyph, drawn as a family-tagged text run. Anything else draws nothing.
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
