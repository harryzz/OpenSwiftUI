//
//  WasmThreadingShim.swift
//  OpenSwiftUICore
//
//  wandr (OpenSwiftUI-on-wasm phase 1): single-threaded WASI substitutes for the
//  Foundation threading / run-loop primitives that swift-corelibs-foundation
//  excludes on os(WASI). wasip1 is single-threaded, so "the main thread" is the
//  only thread and thread-local storage degenerates to plain process globals.
//
//  Covers exactly the surface OpenSwiftUICore uses:
//    - Thread.isMainThread          (ThreadUtils/MainActorUtils/ObservationUtils/…)
//    - pthread TLS                  (ThreadSpecific in ThreadUtils.swift)
//    - a main-run-loop enqueue seam (RunLoopUtils.swift / TimerUtils.swift)
//
//  RunLoop itself is `@available(*, unavailable)` on WASI (even `RunLoop.main`
//  traps at type-check), so the RunLoop call sites are #if-guarded to route here
//  instead of extending RunLoop.

#if os(WASI)
import Foundation

// MARK: - Thread

/// Single-threaded WASI shim for `Foundation.Thread` (absent on os(WASI)).
/// Everything runs on the one and only (main) thread.
package enum Thread {
    package static var isMainThread: Bool { true }

    /// No scheduler on single-threaded wasm — there is nothing to yield to, so
    /// "sleeping" is a no-op. (Used only by test-harness run-loop pumping.)
    /// `Double` not `TimeInterval`: Foundation is imported `internal` here, so a
    /// `package` method can't expose the `TimeInterval` alias.
    package static func sleep(forTimeInterval ti: Double) {}
}

// MARK: - pthread thread-local storage

// wasi-libc declares these in <pthread.h> but they are not surfaced to Swift's
// WASILibc module on the single-threaded SDK. Re-provide them in pure Swift:
// with one thread, TLS is just a process-global keyed table. `pthread_key_t`
// itself IS visible from WASILibc (typedef unsigned), so we reuse it.
// (Internal, not package: imported C types are internal, and only this module
// uses ThreadSpecific.)

private final class _WasmTLS {
    static let shared = _WasmTLS()
    var next: pthread_key_t = 1
    var values: [pthread_key_t: UnsafeMutableRawPointer] = [:]
}

@discardableResult
func pthread_key_create(
    _ key: UnsafeMutablePointer<pthread_key_t>,
    _ destructor: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?
) -> Int32 {
    // Destructors only run at thread exit; the single wasm thread never exits
    // before process teardown, so we don't retain them (ThreadSpecific.deinit is
    // a preconditionFailure anyway — these live for the process lifetime).
    let tls = _WasmTLS.shared
    key.pointee = tls.next
    tls.next &+= 1
    return 0
}

func pthread_getspecific(_ key: pthread_key_t) -> UnsafeMutableRawPointer? {
    _WasmTLS.shared.values[key]
}

@discardableResult
func pthread_setspecific(_ key: pthread_key_t, _ value: UnsafeMutableRawPointer?) -> Int32 {
    if let value {
        _WasmTLS.shared.values[key] = value
    } else {
        _WasmTLS.shared.values.removeValue(forKey: key)
    }
    return 0
}

// MARK: - Timer

// Foundation.Timer compiles on WASI but its implementation references CFRunLoopTimer*
// (unresolved at link). Shadow it module-wide with a minimal stand-in covering the
// surface OpenSwiftUICore uses (TimerUtils.withDelay, EventBindingManager, the
// hosting views). Timers are wired to the host frame clock in a later phase; for
// now they never fire — only construction + invalidate must be total.
package final class Timer {
    package init(timeInterval: Double, repeats: Bool, block: @escaping (Timer) -> Void) {}
    package func invalidate() {}
}

// MARK: - Main run-loop enqueue seam

// swift-corelibs-foundation makes `RunLoop` unavailable on WASI, so blocks that
// the core would defer to `RunLoop.main.perform(inModes:block:)` are queued onto
// a process-global pump drained by the host frame loop (phase 3). Timers are
// no-ops until wired to the host frame clock.

private var _wasmMainRunLoopQueue: [() -> Void] = []

/// Enqueues a block for the next host frame (the WASI replacement for
/// `RunLoop.main.perform(inModes:block:)`).
func _wasmEnqueueMainRunLoop(_ block: @escaping () -> Void) {
    _wasmMainRunLoopQueue.append(block)
}

/// Drains blocks scheduled via `_wasmEnqueueMainRunLoop`.
/// The wandr host calls this once per frame (phase 3). Returns whether work ran.
@discardableResult
package func _wasmDrainMainRunLoop() -> Bool {
    guard !_wasmMainRunLoopQueue.isEmpty else { return false }
    let pending = _wasmMainRunLoopQueue
    _wasmMainRunLoopQueue.removeAll(keepingCapacity: true)
    for block in pending { block() }
    return true
}
#endif
