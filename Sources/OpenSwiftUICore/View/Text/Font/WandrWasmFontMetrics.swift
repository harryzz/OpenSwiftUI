//
//  WandrWasmFontMetrics.swift
//  OpenSwiftUICore
//
//  Text-style / Dynamic Type sizing for platforms without CoreText (wasm, Linux).
//  On Apple platforms CTFontDescriptorGetTextStyleSize supplies these; here they are the
//  single source of truth. Values are the iOS default metrics at the `.large` content size.
//

#if !canImport(CoreText)

public import Foundation

extension Font.TextStyle {
    /// The system point size for this text style at the default (`.large`) Dynamic Type size.
    /// iOS reference metrics — one named table rather than magic numbers scattered per call site.
    package var wandrBasePointSize: CGFloat {
        switch self {
        case .extraLargeTitle2: 40
        case .extraLargeTitle: 36
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline: 17
        case .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        case .caption3: 11
        }
    }
}

extension DynamicTypeSize {
    /// Scale of each standard Dynamic Type size relative to `.large` (= 1.0), matching the
    /// iOS default type-size ramp. Applied to `Font.TextStyle.wandrBasePointSize`.
    package var wandrScale: CGFloat {
        switch self {
        case .xSmall: 0.882
        case .small: 0.941
        case .medium: 0.971
        case .large: 1.0
        case .xLarge: 1.118
        case .xxLarge: 1.235
        case .xxxLarge: 1.353
        case .accessibility1: 1.643
        case .accessibility2: 1.941
        case .accessibility3: 2.353
        case .accessibility4: 2.764
        case .accessibility5: 3.118
        }
    }
}

extension Font.TextStyle {
    /// Resolved point size for this style at a given Dynamic Type size.
    package func wandrPointSize(at dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        (wandrBasePointSize * dynamicTypeSize.wandrScale).rounded()
    }
}

#endif
