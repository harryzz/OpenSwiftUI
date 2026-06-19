//
//  ProtocolDescriptor.c
//  OpenSwiftUI_SPI
//
//  Audit for 6.5.4
//  Status: Complete

#include "ProtocolDescriptor.h"

void _OpenSwiftUI_callVisitViewType(void *visitor_value,
                                    const void *view_type,
                                    const void *view_type2,
                                    const void *view_pwt);

OPENSWIFTUI_EXPORT
const void *$s15OpenSwiftUICore4ViewMp;

const void *_OpenSwiftUI_viewProtocolDescriptor(void) {
    return &$s15OpenSwiftUICore4ViewMp;
}

OPENSWIFTUI_EXPORT
const void *$s15OpenSwiftUICore12ViewModifierMp;

const void *_OpenSwiftUI_viewModifierProtocolDescriptor(void) {
    return &$s15OpenSwiftUICore12ViewModifierMp;
}

OPENSWIFTUI_EXPORT
const void *$s15OpenSwiftUICore7GestureMp;

const void *_OpenSwiftUI_gestureProtocolDescriptor(void) {
    return &$s15OpenSwiftUICore7GestureMp;
}

OPENSWIFTUI_EXPORT
const void *$s15OpenSwiftUICore15GestureModifierMp;

const void *_OpenSwiftUI_gestureModifierProtocolDescriptor(void) {
    return &$s15OpenSwiftUICore15GestureModifierMp;
}

OPENSWIFTUI_EXPORT
const void *$s15OpenSwiftUICore20DefaultStyleModifierMp;

const void *_OpenSwiftUI_defaultStyleModifierProtocolDescriptor(void) {
    return &$s15OpenSwiftUICore15GestureModifierMp;
}

OPENSWIFTUI_EXPORT
const void *$s15OpenSwiftUICore21StyleOverrideModifierMp;

const void *_OpenSwiftUI_styleOverrideModifierProtocolDescriptor(void) {
    return &$s15OpenSwiftUICore21StyleOverrideModifierMp;
}

OPENSWIFTUI_EXPORT
const void *$s15OpenSwiftUICore27StyleWriterOverrideModifierMp;

const void *_OpenSwiftUI_styleWriterOverrideModifierProtocolDescriptor(void) {
    return &$s15OpenSwiftUICore27StyleWriterOverrideModifierMp;
}

OPENSWIFTUI_EXPORT
const void *$s15OpenSwiftUICore12StyleContextMp;

const void *_OpenSwiftUI_styleContextProtocolDescriptor(void) {
    return &$s15OpenSwiftUICore12StyleContextMp;
}

#if defined(__wasi__)
// swift_conformsToProtocol is declared C_CC in the Swift runtime
// (RuntimeFunctions.def: `Swift, swift_conformsToProtocol, C_CC, ...`). Forward to it
// with the C ABI so Swift's call lowers to a matching wasm signature (the direct
// @_silgen_name call mislowers -> signature_mismatch on wasm).
extern const void *swift_conformsToProtocol(const void *type, const void *protocolDescriptor);

const void *_OpenSwiftUI_conformsToProtocol(const void *type, const void *protocolDescriptor) {
    return swift_conformsToProtocol(type, protocolDescriptor);
}
#endif
