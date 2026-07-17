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
            if let raw = UserDefaultsStore.standard.object(forKey: key) as? T {
                values[key] = raw
                return raw
            }
        }
        return defaultValue
    }

    func set<T>(_ value: T, for key: String) {
        values[key] = value
        hydratedKeys.insert(key)
        UserDefaultsStore.standard.set(value, forKey: key)
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

// MARK: - UserDefaultsStore

/// The real, shared persistence engine `@AppStorage` uses — and, via apple-compat's `UserDefaults`
/// shim (which delegates here), so does plain `UserDefaults` — matching Apple's own actual
/// relationship between the two (real `@AppStorage` is a thin reactive wrapper OVER
/// `UserDefaults`, not a separate store). One real XML plist file per SUITE (not per key) under
/// `/state` — `/state/<suite>.plist` — matching how real `UserDefaults` actually persists (one
/// domain = one plist), a universal wandr convention (every guest gets a read-write `/state` dir
/// regardless of which renderer path it runs through).
public final class UserDefaultsStore: @unchecked Sendable {
    public static let standard = UserDefaultsStore(suiteName: "standard")

    nonisolated(unsafe) private static var suites: [String: UserDefaultsStore] = [:]

    public static func suite(_ name: String) -> UserDefaultsStore {
        if let existing = suites[name] { return existing }
        let store = UserDefaultsStore(suiteName: name)
        suites[name] = store
        return store
    }

    private let suiteName: String
    private var cache: [String: Any]?

    private init(suiteName: String) {
        self.suiteName = suiteName
    }

    private var path: String { "/state/\(suiteName).plist" }

    private func load() -> [String: Any] {
        if let cache { return cache }
        guard let file = fopen(path, "rb") else {
            cache = [:]
            return [:]
        }
        defer { fclose(file) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let read = buffer.withUnsafeMutableBytes { fread($0.baseAddress, 1, $0.count, file) }
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        let result = dict ?? [:]
        cache = result
        return result
    }

    private func save(_ dict: [String: Any]) {
        cache = dict
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else {
            return
        }
        guard let file = fopen(path, "wb") else { return }
        defer { fclose(file) }
        data.withUnsafeBytes { buf in
            _ = fwrite(buf.baseAddress, 1, buf.count, file)
        }
    }

    public func object(forKey key: String) -> Any? { load()[key] }

    public func set(_ value: Any?, forKey key: String) {
        var dict = load()
        dict[key] = value
        save(dict)
    }

    public func removeObject(forKey key: String) {
        var dict = load()
        dict.removeValue(forKey: key)
        save(dict)
    }

    public func integer(forKey key: String) -> Int { (load()[key] as? Int) ?? 0 }
    public func bool(forKey key: String) -> Bool { (load()[key] as? Bool) ?? false }
    public func double(forKey key: String) -> Double { (load()[key] as? Double) ?? 0 }
    public func float(forKey key: String) -> Float { (load()[key] as? Float) ?? 0 }
    public func string(forKey key: String) -> String? { load()[key] as? String }
}
#endif
