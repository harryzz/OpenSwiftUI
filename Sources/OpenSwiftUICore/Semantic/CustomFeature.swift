//
//  UnifiedHitTestingFeature.swift
//  OpenSwiftUICore
//
//  Audited for 6.5.4
//  Status: Partial

// MARK: - UnifiedHitTestingFeature

package struct UnifiedHitTestingFeature: Feature {
    package init() {
        _openSwiftUIEmptyStub()
    }

    package static var isEnabled: Bool {
        Semantics.UnifiedHitTesting.isEnabled || GestureContainerFeature.isEnabled
    }
}

// TODO

// MARK: GestureContainerFeature [TODO]

struct GestureContainerFeature {
    // [wandr] Enabled: turns on the geometric bind path in GestureResponder.bindEvent (hit-test by
    // location against leaf-responder frames) instead of the structural first-gesture fallback.
    // Requires geometry-carrying leaf responders (RendererLeafView.makeLeafView emits them).
    static var isEnabled: Bool {
        true
    }
}
