//
//  Button.swift
//  OpenSwiftUI
//
//  Audited for 3.5.2
//  Status: WIP (label rendering + ButtonStyle application; PrimitiveButtonStyle/role not yet wired)

package import OpenSwiftUICore

public struct Button<Label>: View where Label: View {
    @usableFromInline
    let action: () -> Void
    @usableFromInline
    let label: Label
    // [wandr] The current `.buttonStyle`'s makeBody, type-erased (nil = no style set).
    @Environment(\.buttonStyleApplier)
    private var styleApplier: ((ButtonStyleConfiguration) -> AnyView)?

    public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    // Render the label (previously `EmptyView()`, so every Button showed nothing). When a
    // `.buttonStyle` is set, run its `makeBody(configuration:)` and bind `configuration.label`
    // (a ViewAlias) to the real label so styled buttons (e.g. a filled-background modal button)
    // draw their background/text instead of an invisible label. Tap dispatch rides `onTapGesture`.
    // Button *role* and pressed-state tracking (`isPressed`) are not wired yet.
    @ViewBuilder
    public var body: some View {
        if let styleApplier {
            styleApplier(ButtonStyleConfiguration(isPressed: false, role: nil))
                .viewAlias(ButtonStyleConfiguration.Label.self) { label }
                .onTapGesture(perform: action)
        } else {
            label.onTapGesture(perform: action)
        }
    }
}

// MARK: - ButtonStyle application [wandr]

private struct ButtonStyleApplierKey: EnvironmentKey {
    static let defaultValue: ((ButtonStyleConfiguration) -> AnyView)? = nil
}

extension EnvironmentValues {
    package var buttonStyleApplier: ((ButtonStyleConfiguration) -> AnyView)? {
        get { self[ButtonStyleApplierKey.self] }
        set { self[ButtonStyleApplierKey.self] = newValue }
    }
}

@available(OpenSwiftUI_v1_0, *)
extension View {
    /// Sets the style for buttons within this view to a button style with a custom appearance and
    /// standard interaction behavior.
    ///
    /// [wandr] Real implementation (the eleev SwiftUI shim stubbed it to a no-op): stores the
    /// style's `makeBody` type-erased in the environment; `Button` applies it, binding the
    /// configuration's `label` ViewAlias to the button's real label. Closest style wins (overwrite).
    nonisolated public func buttonStyle<S>(_ style: S) -> some View where S: ButtonStyle {
        environment(\.buttonStyleApplier) { configuration in
            AnyView(style.makeBody(configuration: configuration))
        }
    }
}
