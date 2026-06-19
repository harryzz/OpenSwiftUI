//
//  OpenSwiftUI_CSymbols.c
//  OpenSwiftUI_SPI

#include "OpenSwiftUI_CSymbols.h"
#if !defined(__wasi__)
#include <dlfcn.h>
#endif

const char * getSymbolPathName(const void *address) {
#if defined(__wasi__)
    (void)address;
    return NULL;   // wasm: no dynamic linking (dladdr/Dl_info absent) — debug-only path
#else
    Dl_info info;
    int result = dladdr(address, &info);
    if (result == 0) {
        return NULL;
    }
    return info.dli_fname;
#endif
}
