//
//  TLS.c
//  OpenSwiftUI_SPI
//
//  Audited for 6.4.41
//  Status: Complete

#include "TLS.h"
#include <stdatomic.h>

// [wasm32] wasm32-wasip1 is single-threaded and `_Thread_local` TLS is not initialized in this
// toolchain (no TLS segment setup) → reads/writes hit a garbage/aliased slot, so the layout
// `placementData` pointer does not round-trip and `setGeometry` sprays a ViewGeometry CGFloat over
// adjacent (subgraph-pointer) memory → SIGSEGV. Single-threaded ⇒ a plain `static` global IS the TLS.
#if defined(__wasi__)
#define OPENSWIFTUI_TLS
#else
#define OPENSWIFTUI_TLS _Thread_local
#endif

static OPENSWIFTUI_TLS void * _perThreadGeometryProxyData = NULL;
static OPENSWIFTUI_TLS int64_t _perThreadUpdateCount = 0;
static OPENSWIFTUI_TLS uint32_t _perThreadTransactionID = 0;
static OPENSWIFTUI_TLS void * _perThreadTransactionData = NULL;
static OPENSWIFTUI_TLS void * _perThreadLayoutData = NULL;

void _setThreadGeometryProxyData(void * data) {
    _perThreadGeometryProxyData = data;
}

void * _threadGeometryProxyData(void) {
    return _perThreadGeometryProxyData;
}

uint32_t _threadTransactionID(bool increase) {
    if (!increase && _perThreadTransactionID != 0) {
        return _perThreadTransactionID;
    } else {
        static atomic_int last_id = 0;
        uint32_t result = atomic_fetch_add_explicit(&last_id, 1, memory_order_relaxed);
        result += 1;
        _perThreadTransactionID = result;
        return result;
    }
}

void _setThreadTransactionData(void * data) {
    _perThreadTransactionData = data;
}

void * _threadTransactionData(void) {
    return _perThreadTransactionData;
}

void _setThreadLayoutData(void * data) {
    _perThreadLayoutData = data;
}

void *_threadLayoutData(void) {
    return _perThreadLayoutData;
}
