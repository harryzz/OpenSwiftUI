//
//  RunLoopUtils.swift
//  OpenSwiftUICore
//
//  Audited for 6.0.87
//  Status: Complete
//  ID: 904CE3B9A8258172D2E69C7BF94D1428 (SwiftUICore)

package import Foundation

#if !canImport(ObjectiveC)
package import CoreFoundation

/// A compactible implementation for the autoreleasepool API
@inlinable
package func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}

#if !os(WASI)
extension CFRunLoopMode {
    package static let defaultMode: CFRunLoopMode! = kCFRunLoopDefaultMode
    package static let commonModes: CFRunLoopMode! = kCFRunLoopCommonModes
}
#endif
#endif

package func onNextMainRunLoop(do body: @escaping () -> Void) {
    #if os(WASI)
    // RunLoop is unavailable on WASI; defer to the host frame loop instead.
    _wasmEnqueueMainRunLoop(body)
    #else
    RunLoop.main.perform(inModes: [.common], block: body)
    #endif
}

#if !os(WASI)
private var observer: CFRunLoopObserver?
#endif
private var observerActions: [() -> Void] = []

extension RunLoop {
    package static func addObserver(_ action: @escaping () -> Void) {
        #if os(WASI)
        // No CFRunLoop on wasm: just queue the action. The host frame loop drains
        // it via flushObservers() (wired through _wasmDrainMainRunLoop in phase 3).
        observerActions.append(action)
        #else
        let currentRunloop = CFRunLoopGetCurrent()
        if observer == nil {
            observer = CFRunLoopObserverCreate(
                kCFAllocatorDefault,
                CFRunLoopActivity([.beforeWaiting, .exit]).rawValue,
                true,
                0,
                { _, _, _ in
                    autoreleasepool {
                        RunLoop.flushObservers()
                    }
                },
                nil
            )
            CFRunLoopAddObserver(currentRunloop, observer, .commonModes)
        }
        let currentMode = CFRunLoopCopyCurrentMode(currentRunloop)
        if let currentMode {
            if !CFRunLoopContainsObserver(currentRunloop, observer, currentMode) {
                CFRunLoopAddObserver(currentRunloop, observer, currentMode)
            }
        }
        observerActions.append(action)
        #endif
    }

    package static func flushObservers() {
        while !observerActions.isEmpty {
            let actions = observerActions
            observerActions = []
            Update.begin()
            for action in actions {
                action()
            }
            Update.end()
        }
    }

    #if os(WASI)
    // No CFRunLoop to run on wasm; the host frame loop owns time. No-op.
    package static func runAllowingEarlyExit(until deadline: Date, stopCondition: () -> Bool) {}

    package static func runAllowingEarlyExit(until deadline: Date) {}
    #else
    package static func runAllowingEarlyExit(until deadline: Date, stopCondition: () -> Bool) {
        repeat {
            let diff = deadline.timeIntervalSinceReferenceDate - CFAbsoluteTimeGetCurrent()
            guard diff > 0 else {
                return
            }
            let result = autoreleasepool {
                CFRunLoopRunInMode(.defaultMode, diff, true)
            }
            guard result == .handledSource, !stopCondition() else {
                return
            }
        } while true
    }

    package static func runAllowingEarlyExit(until deadline: Date) {
        runAllowingEarlyExit(until: deadline) { false }
    }
    #endif
}
