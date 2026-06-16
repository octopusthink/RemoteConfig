//
//  RemoteConfigValue.swift
//  RemoteConfig
//

import Foundation

/**
 A lightweight, dynamically-typed wrapper around a single remote configuration
 value.

 The API intentionally mirrors Firebase's `RemoteConfigValue`, so values can be
 coerced into the most common types regardless of how they were encoded in the
 source JSON. Access typed values through the convenience properties
 (``boolValue``, ``stringValue``, …) or decode structured values with
 ``decoded(as:)``.
 */
public struct RemoteConfigValue: @unchecked Sendable {
    /// The underlying value as decoded from JSON (`Bool`, `String`, `NSNumber`,
    /// arrays, dictionaries, or `nil` when the key is absent).
    ///
    /// The wrapper is `@unchecked Sendable`: the values produced by
    /// `JSONSerialization` are immutable value types (or thread-safe
    /// `NSNumber`/`NSString` bridges), so sharing them across concurrency
    /// domains is safe.
    public let rawValue: Any?

    /// Creates a value wrapper around a raw JSON value.
    public init(rawValue: Any?) {
        self.rawValue = rawValue
    }

    /// The value coerced to a `Bool`.
    ///
    /// Strings such as `"true"`/`"yes"`/`"1"` and non-zero numbers are treated
    /// as `true`. Returns `false` when the value is missing or unconvertible.
    public var boolValue: Bool {
        if let bool = rawValue as? Bool { return bool }
        if let string = rawValue as? String {
            switch string.lowercased() {
            case "true", "yes", "1": return true
            default: return false
            }
        }
        if let number = rawValue as? NSNumber { return number.boolValue }
        return false
    }

    /// The value coerced to an `NSNumber`. Returns `0` when unconvertible.
    public var numberValue: NSNumber {
        if let number = rawValue as? NSNumber { return number }
        if let bool = rawValue as? Bool { return NSNumber(value: bool) }
        if let int = rawValue as? Int { return NSNumber(value: int) }
        if let double = rawValue as? Double { return NSNumber(value: double) }
        if let string = rawValue as? String, let doubleValue = Double(string) {
            return NSNumber(value: doubleValue)
        }
        return NSNumber(value: 0)
    }

    /// The value coerced to an `Int`.
    public var intValue: Int { numberValue.intValue }

    /// The value coerced to a `Double`.
    public var doubleValue: Double { numberValue.doubleValue }

    /// The value as a `String`, or `nil` when the key is absent.
    public var stringValue: String? {
        if let string = rawValue as? String { return string }
        if let rawValue { return String(describing: rawValue) }
        return nil
    }

    /// The raw, untyped JSON value (array, dictionary, scalar, or `nil`).
    public var jsonValue: Any? { rawValue }

    /// The value as a `[String: String]` dictionary, or `nil`.
    public var stringDictionaryValue: [String: String]? {
        rawValue as? [String: String]
    }

    /// The value as a `[String]` array, or `nil`.
    public var stringArrayValue: [String]? {
        rawValue as? [String]
    }

    /**
     Decodes a structured value into a `Decodable` type.

     The raw JSON value (an array or dictionary) is re-serialized and decoded
     with `JSONDecoder`, making it possible to map remote structures directly
     onto your own `Codable` models. For scalar values prefer the typed
     properties (``boolValue``, ``intValue``, ``stringValue``).

     - Returns: The decoded value, or `nil` when the value is missing or cannot
       be decoded into the requested type.
     */
    public func decoded<T: Decodable>(as type: T.Type) -> T? {
        guard let rawValue, JSONSerialization.isValidJSONObject(rawValue) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: rawValue) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
