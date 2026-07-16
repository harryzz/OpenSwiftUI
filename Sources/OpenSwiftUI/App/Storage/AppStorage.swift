//
//  AppStorage.swift
//  OpenSwiftUI
//
//  A working @AppStorage: participates in the same DynamicProperty/_makeProperty machinery @State
//  uses (OpenSwiftUICore/Data/State/State.swift), so a write correctly invalidates every View whose
//  body read the key. Upstream reserves `appStorageSignal` (OpenSwiftUICore/Util/
//  AttributeGraphAdditions.swift) for exactly this — see github.com/OpenSwiftUIProject/OpenSwiftUI
//  issue #769 — but has never implemented it (empty tracking issue, no PR, no body).
//
//  Apple's real AppStorage (confirmed from the public SwiftUI.swiftinterface) backs onto a shared,
//  KEYED `UserDefaultLocation<Value>` — a `Location`-shaped class (get / set(transaction:) / update()
//  / wasRead) with no Attribute or subgraph in its own storage; the graph-side notification is wired
//  up separately, per View, through `_makeProperty`. This mirrors that split:
//   - AppStorageBox (below) holds the actual value in a plain keyed dictionary — no Attribute, no
//     subgraph, no host reference required for it to exist.
//   - Each View's own `_makeProperty` call creates a private signal Attribute — always safe, since
//     `_makeProperty` only ever runs during real view instantiation, where a subgraph is guaranteed
//     — and registers it with the shared box, so a `set` can invalidate every currently-live reader.
//  A prior attempt backed AppStorage directly with a subgraph-owned Attribute/StoredLocation and
//  wrote to it synchronously from a gesture handler; that corrupted the graph ("cannot enter
//  component instance" / AttributeID assertion) because it bypassed the deferred, transaction-safe
//  commit this design (and StoredLocation itself) uses.
#if !OPENSWIFTUI_SWIFTUI_RENDERER
package import OpenAttributeGraphShims
@_spi(ForOpenSwiftUIOnly) import OpenSwiftUICore
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(WASI)
import WASILibc
#endif

@propertyWrapper
public struct AppStorage<Value>: DynamicProperty {
    let key: String
    let defaultValue: Value

    public init(wrappedValue: Value, _ key: String) {
        self.key = key
        self.defaultValue = wrappedValue
    }

    public var wrappedValue: Value {
        get { AppStorageRegistry.shared.get(key, default: defaultValue) }
        nonmutating set { AppStorageRegistry.shared.set(newValue, for: key) }
    }

    public var projectedValue: Binding<Value> {
        Binding(
            get: { AppStorageRegistry.shared.get(key, default: defaultValue) },
            set: { AppStorageRegistry.shared.set($0, for: key) }
        )
    }

    public static func _makeProperty<V>(
        in buffer: inout _DynamicPropertyBuffer,
        container: _GraphValue<V>,
        fieldOffset: Int,
        inputs: inout _GraphInputs
    ) {
        let attribute = Attribute(value: ())
        let box = AppStoragePropertyBox<Value>(signal: WeakAttribute(attribute))
        buffer.append(box, fieldOffset: fieldOffset)
        addTreeValue(attribute, as: Value.self, at: fieldOffset, in: V.self, flags: .appStorageSignal)
    }
}

// MARK: - AppStoragePropertyBox

private struct AppStoragePropertyBox<Value>: DynamicPropertyBox {
    let signal: WeakAttribute<Void>
    var registeredKey: String?

    typealias Property = AppStorage<Value>

    mutating func update(property: inout AppStorage<Value>, phase: ViewPhase) -> Bool {
        if registeredKey != property.key {
            AppStorageRegistry.shared.register(signal: signal, for: property.key)
            registeredKey = property.key
        }
        return signal.changedValue()?.changed ?? false
    }

    func destroy() {
        guard let registeredKey else { return }
        AppStorageRegistry.shared.unregister(signal: signal, for: registeredKey)
    }
}

// MARK: - AppStorageRegistry

/// The wandr equivalent of Apple's `UserDefaultLocation<Value>` — a single shared registry holding
/// every key's value in a plain dictionary, plus a list of currently-registered per-View signal
/// Attributes to invalidate on write. Not generic over Value itself (Swift disallows stored static
/// properties on generic types) — values are stored as `Any` and cast back at each generic call
/// site, matching how a single string key is assumed to always carry one consistent Value type
/// (the same assumption Apple's own UserDefaults-keyed storage makes).
private final class AppStorageRegistry: @unchecked Sendable {
    static let shared = AppStorageRegistry()

    private var values: [String: Any] = [:]
    private var signals: [String: [WeakAttribute<Void>]] = [:]
    private var hydratedKeys: Set<String> = []

    private init() {}

    func get<T>(_ key: String, default defaultValue: T) -> T {
        if let cached = values[key] as? T {
            return cached
        }
        // First access for this key this run — try disk before falling back to defaultValue.
        if !hydratedKeys.contains(key) {
            hydratedKeys.insert(key)
            if let persistableType = T.self as? any AppStoragePersistable.Type,
               let raw = AppStoragePersistence.read(key: key),
               let decoded = persistableType.init(persistedStringValue: raw) as? T {
                values[key] = decoded
                return decoded
            }
        }
        return defaultValue
    }

    func set<T>(_ value: T, for key: String) {
        values[key] = value
        hydratedKeys.insert(key)
        if let persistable = value as? any AppStoragePersistable {
            AppStoragePersistence.write(key: key, value: persistable.persistedStringValue)
        }
        guard let observers = signals[key], !observers.isEmpty else { return }
        // Mirrors StoredLocationBase.set()'s own safety pattern: defer the actual graph
        // invalidation via onMainThread rather than firing it synchronously inline with the write.
        onMainThread {
            for weakSignal in observers {
                weakSignal.attribute?.invalidateValue()
            }
        }
    }

    func register(signal: WeakAttribute<Void>, for key: String) {
        signals[key, default: []].append(signal)
    }

    func unregister(signal: WeakAttribute<Void>, for key: String) {
        signals[key]?.removeAll { $0 == signal }
    }
}

// MARK: - Persistence

/// The primitive types Apple's real AppStorage supports natively (Bool/Int/Double/String — RawRepresentable,
/// URL, and Data are not needed by any current wandr guest and are left out rather than guessed at).
private protocol AppStoragePersistable {
    var persistedStringValue: String { get }
    init?(persistedStringValue: String)
}

extension Bool: AppStoragePersistable {
    var persistedStringValue: String { self ? "1" : "0" }
    init?(persistedStringValue: String) { self = persistedStringValue == "1" }
}

extension Int: AppStoragePersistable {
    var persistedStringValue: String { String(self) }
    init?(persistedStringValue: String) { self.init(persistedStringValue) }
}

extension Double: AppStoragePersistable {
    var persistedStringValue: String { String(self) }
    init?(persistedStringValue: String) { self.init(persistedStringValue) }
}

extension String: AppStoragePersistable {
    var persistedStringValue: String { self }
    init?(persistedStringValue: String) { self = persistedStringValue }
}

/// Same minimal POSIX read/write style as WandrBoardSizeStore/WandrPlist — plain files under the
/// app's `/state` preopen (a universal wandr convention, not per-app config: every guest gets a
/// read-write `/state` dir regardless of which renderer path it runs through).
private enum AppStoragePersistence {
    static func read(key: String) -> String? {
        guard let file = fopen(path(for: key), "rb") else { return nil }
        defer { fclose(file) }
        var buffer = [UInt8](repeating: 0, count: 256)
        let n = buffer.withUnsafeMutableBytes { fread($0.baseAddress, 1, $0.count, file) }
        guard n > 0, let s = String(bytes: buffer[0..<n], encoding: .utf8) else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func write(key: String, value: String) {
        guard let file = fopen(path(for: key), "wb") else { return }
        defer { fclose(file) }
        _ = value.withCString { fwrite($0, 1, strlen($0), file) }
    }

    private static func path(for key: String) -> String {
        "/state/appstorage-\(key)"
    }
}
#endif
