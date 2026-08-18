import Combine
import Foundation

/// Where `@Stored` reads and writes. A non-generic home, because a generic type cannot hold a
/// static stored property — and `--self-test` needs to point this at a scratch suite.
enum PreferenceStore {
    nonisolated(unsafe) static var defaults: UserDefaults = .standard
}

/// A value that round-trips through `UserDefaults`.
protocol DefaultsValue {
    static func read(from defaults: UserDefaults, key: String) -> Self?
    func write(to defaults: UserDefaults, key: String)
}

extension Bool: DefaultsValue {
    static func read(from defaults: UserDefaults, key: String) -> Bool? {
        defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key)
    }
    func write(to defaults: UserDefaults, key: String) { defaults.set(self, forKey: key) }
}

extension Double: DefaultsValue {
    static func read(from defaults: UserDefaults, key: String) -> Double? {
        defaults.object(forKey: key) == nil ? nil : defaults.double(forKey: key)
    }
    func write(to defaults: UserDefaults, key: String) { defaults.set(self, forKey: key) }
}

extension Int: DefaultsValue {
    static func read(from defaults: UserDefaults, key: String) -> Int? {
        defaults.object(forKey: key) == nil ? nil : defaults.integer(forKey: key)
    }
    func write(to defaults: UserDefaults, key: String) { defaults.set(self, forKey: key) }
}

extension String: DefaultsValue {
    static func read(from defaults: UserDefaults, key: String) -> String? {
        defaults.string(forKey: key)
    }
    func write(to defaults: UserDefaults, key: String) { defaults.set(self, forKey: key) }
}

extension Array: DefaultsValue where Element == String {
    static func read(from defaults: UserDefaults, key: String) -> [String]? {
        defaults.stringArray(forKey: key)
    }
    func write(to defaults: UserDefaults, key: String) { defaults.set(self, forKey: key) }
}

/// One preference: its key, its default, and where it is stored — declared once.
///
/// The old shape was a hand-synced triple per setting (a `@Published` with a `didSet` that wrote,
/// an entry in `register(defaults:)`, and a read-back in `init`). At 17 settings that was merely
/// repetitive; the settings list is now roughly twice that, and the failure mode is not
/// hypothetical — five shipped toggles wrote a value that nothing ever read.
///
/// This also buys reset-to-defaults and export/import, which are otherwise another list to keep
/// in sync by hand.
@propertyWrapper
struct Stored<Value: DefaultsValue> {
    let key: String
    let defaultValue: Value
    private var cached: Value?

    init(wrappedValue: Value, _ key: String) {
        self.key = key
        self.defaultValue = wrappedValue
    }

    /// Only reachable when a `Stored` is used outside an `ObservableObject`, which nothing does.
    @available(*, unavailable, message: "@Stored is only usable inside an ObservableObject")
    var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }

    static subscript<Enclosing: ObservableObject>(
        _enclosingInstance instance: Enclosing,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<Enclosing, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<Enclosing, Self>
    ) -> Value where Enclosing.ObjectWillChangePublisher == ObservableObjectPublisher {
        get {
            let box = instance[keyPath: storageKeyPath]
            if let cached = box.cached { return cached }
            let value = Value.read(from: box.store, key: box.key) ?? box.defaultValue
            instance[keyPath: storageKeyPath].cached = value
            return value
        }
        set {
            instance.objectWillChange.send()
            instance[keyPath: storageKeyPath].cached = newValue
            let box = instance[keyPath: storageKeyPath]
            newValue.write(to: box.store, key: box.key)
        }
    }

    /// Overridable so `--self-test` can drive a scratch domain instead of the real one.
    var store: UserDefaults { PreferenceStore.defaults }

    /// Forget the in-memory copy, so the next read comes from disk again.
    mutating func invalidate() { cached = nil }
}
