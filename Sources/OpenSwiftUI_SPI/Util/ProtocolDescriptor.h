//
//  ProtocolDescriptor_h
//  OpenSwiftUI_SPI
//
//  Audit for 6.5.4
//  Status: Complete

#ifndef ProtocolDescriptor_h
#define ProtocolDescriptor_h

#include "OpenSwiftUIBase.h"

OPENSWIFTUI_ASSUME_NONNULL_BEGIN

OPENSWIFTUI_EXPORT
const void *_OpenSwiftUI_viewProtocolDescriptor(void) OPENSWIFTUI_SWIFT_NAME(_viewProtocolDescriptor());

OPENSWIFTUI_EXPORT
const void *_OpenSwiftUI_viewModifierProtocolDescriptor(void) OPENSWIFTUI_SWIFT_NAME(_viewModifierProtocolDescriptor());

OPENSWIFTUI_EXPORT
const void *_OpenSwiftUI_gestureProtocolDescriptor(void) OPENSWIFTUI_SWIFT_NAME(_gestureProtocolDescriptor());

OPENSWIFTUI_EXPORT
const void *_OpenSwiftUI_gestureModifierProtocolDescriptor(void) OPENSWIFTUI_SWIFT_NAME(_gestureModifierProtocolDescriptor());

OPENSWIFTUI_EXPORT
const void *_OpenSwiftUI_defaultStyleModifierProtocolDescriptor(void) OPENSWIFTUI_SWIFT_NAME(_defaultStyleModifierProtocolDescriptor());

OPENSWIFTUI_EXPORT
const void *_OpenSwiftUI_styleOverrideModifierProtocolDescriptor(void) OPENSWIFTUI_SWIFT_NAME(_styleOverrideModifierProtocolDescriptor());

OPENSWIFTUI_EXPORT
const void *_OpenSwiftUI_styleWriterOverrideModifierProtocolDescriptor(void) OPENSWIFTUI_SWIFT_NAME(_styleWriterOverrideModifierProtocolDescriptor());

OPENSWIFTUI_EXPORT
const void *_OpenSwiftUI_styleContextProtocolDescriptor(void) OPENSWIFTUI_SWIFT_NAME(_styleContextProtocolDescriptor());

#if defined(__wasi__)
// WASI: swift_conformsToProtocol is C_CC (Swift RuntimeFunctions.def), but Swift's
// @_silgen_name lowers the call with the Swift CC -> wasm `signature_mismatch`. This
// plain-C wrapper is imported with the C ABI so the call lowers correctly.
OPENSWIFTUI_EXPORT
const void *_Nullable _OpenSwiftUI_conformsToProtocol(const void *type, const void *protocolDescriptor);
#endif

OPENSWIFTUI_ASSUME_NONNULL_END

#endif /* ProtocolDescriptor_h */
