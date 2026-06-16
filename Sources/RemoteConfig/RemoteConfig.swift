//
//  RemoteConfig.swift
//  RemoteConfig
//
//  A small, dependency-free remote configuration / feature-flag loader for all
//  Apple platforms. Loads baseline defaults synchronously on launch, merges any
//  previously cached remote overrides, and periodically refreshes from a remote
//  JSON endpoint — allowing config/feature-flag changes without shipping a new
//  build or restarting the app.
//

import Foundation
import Observation

/**
 Remote configuration values that can be changed remotely without an app update.

 Configure the shared instance once at launch with ``configure(_:)``, then read
 values anywhere via the subscript or the typed accessors:

 ```swift
 // At launch:
 RemoteConfig.configure(
     RemoteConfiguration(
         remoteURL: URL(string: "https://example.com/remote-config.json"),
         defaults: .bundle(.main, resource: "remote-config", extension: "json")
     )
 )

 // Anywhere (main actor):
 if RemoteConfig.shared.bool("featureFlagEnabled") { … }
 let raw = RemoteConfig.shared["someKey"].stringValue
 ```

 The type is `@MainActor`-isolated and `@Observable`, so SwiftUI views that read
 its values automatically update when a remote refresh changes them.
 */
@MainActor
@Observable
public final class RemoteConfig {
    /// The process-wide shared instance.
    ///
    /// Until ``configure(_:)`` is called this holds an empty configuration. It
    /// is safe to read before configuration — values simply fall back to their
    /// type defaults.
    public static let shared = RemoteConfig()

    /// The current, merged configuration values (defaults ← cached ← remote).
    public private(set) var configValues: [String: Any] = [:]

    /// The active configuration. Replaced by ``configure(_:)``.
    public private(set) var configuration = RemoteConfiguration()

    @ObservationIgnored
    private var updateTask: Task<Void, Never>?

    /// Creates an unconfigured instance. Prefer ``shared``; this initializer is
    /// public mainly to support testing with isolated instances.
    public init() {}

    deinit {
        updateTask?.cancel()
    }

    // MARK: - Configuration

    /**
     Configures the ``shared`` instance.

     Loads bundled defaults synchronously, merges any cached remote overrides,
     and (unless disabled) starts the periodic background refresh. Calling this
     more than once re-applies configuration from scratch.
     */
    public static func configure(_ configuration: RemoteConfiguration) {
        shared.apply(configuration)
    }

    /// Applies a configuration to this instance. See ``configure(_:)``.
    public func apply(_ configuration: RemoteConfiguration) {
        updateTask?.cancel()
        updateTask = nil

        self.configuration = configuration
        configValues = [:]

        loadDefaults()
        loadCachedConfig()

        if configuration.automaticallyStartUpdates, configuration.remoteURL != nil {
            startPeriodicUpdates()
        }
    }

    // MARK: - Loading defaults

    private func loadDefaults() {
        let data: Data?

        switch configuration.defaults {
        case .none:
            data = nil
        case let .data(value):
            data = value
        case let .fileURL(url):
            data = try? Data(contentsOf: url)
        case let .bundle(bundle, resource, ext):
            guard let url = bundle.url(forResource: resource, withExtension: ext) else {
                RemoteConfigLog.error("Could not find \(resource).\(ext) in bundle \(bundle.bundleIdentifier ?? "<unknown>").")
                data = nil
                break
            }
            data = try? Data(contentsOf: url)
        }

        guard let data else { return }

        if let json = parse(data) {
            configValues = json
        }
    }

    // MARK: - Caching (UserDefaults-backed)

    private var cachedDataKey: String { "\(configuration.storageKeyPrefix).cachedData" }
    private var lastUpdatedKey: String { "\(configuration.storageKeyPrefix).lastUpdated" }
    private var buildNumberKey: String { "\(configuration.storageKeyPrefix).buildNumber" }

    /// Serializes the current values and saves them as the cached overrides.
    private func saveCachedConfig() {
        do {
            let data = try JSONSerialization.data(withJSONObject: configValues)
            configuration.userDefaults.set(data, forKey: cachedDataKey)
        } catch {
            RemoteConfigLog.error("Error serializing remote config data: \(error.localizedDescription)")
        }
    }

    /// Discards cached overrides, reverting to bundled defaults on next load.
    private func resetCachedConfig() {
        configuration.userDefaults.removeObject(forKey: cachedDataKey)
    }

    /// Merges cached overrides on top of the bundled defaults, after applying
    /// build-number based invalidation.
    private func loadCachedConfig() {
        // Invalidate cached overrides when a newer build ships, so fresh
        // bundled defaults win over potentially stale remote values.
        if let currentBuild = configuration.buildNumberProvider?() {
            let storedBuild = configuration.userDefaults.integer(forKey: buildNumberKey)
            if currentBuild > storedBuild {
                resetCachedConfig()
                configuration.userDefaults.set(currentBuild, forKey: buildNumberKey)
                return
            }
        }

        guard let data = configuration.userDefaults.data(forKey: cachedDataKey) else { return }
        if let json = parse(data) {
            configValues.merge(json) { _, new in new }
        }
    }

    private func parse(_ data: Data) -> [String: Any]? {
        do {
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            RemoteConfigLog.error("Error parsing remote config JSON: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Remote updates

    /// Starts a background task that refreshes on ``RemoteConfiguration/refreshInterval``.
    public func startPeriodicUpdates() {
        guard updateTask == nil else { return }

        let interval = configuration.refreshInterval
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.fetchRemoteUpdates()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Stops the periodic background refresh, if running.
    public func stopPeriodicUpdates() {
        updateTask?.cancel()
        updateTask = nil
    }

    /**
     Fetches the latest configuration from ``RemoteConfiguration/remoteURL`` and
     merges it over the existing values, persisting the result as the cached
     overrides.

     - Parameter forceUpdate: Bypass the ``RemoteConfiguration/minimumFetchInterval``
       throttle and fetch immediately.
     */
    public func fetchRemoteUpdates(forceUpdate: Bool = false) async {
        guard let url = configuration.remoteURL else { return }

        // Throttle: skip unless enough time has elapsed since the last success.
        let lastUpdated = Date(timeIntervalSince1970: configuration.userDefaults.double(forKey: lastUpdatedKey))
        guard forceUpdate || abs(lastUpdated.timeIntervalSinceNow) >= configuration.minimumFetchInterval else {
            return
        }

        do {
            // Network I/O runs off the main actor; `Data` is `Sendable`, so it
            // safely crosses back to the main actor for parsing/merging.
            let (data, _) = try await URLSession.shared.data(from: url)

            guard let json = parse(data) else { return }
            configValues.merge(json) { _, new in new }
            saveCachedConfig()
            configuration.userDefaults.set(Date().timeIntervalSince1970, forKey: lastUpdatedKey)
        } catch {
            RemoteConfigLog.error("Error fetching remote config from \(url.absoluteString): \(error.localizedDescription)")
        }
    }

    // MARK: - Access

    /// Dictionary-style access, e.g. `RemoteConfig.shared["ignoredDevices"]`.
    public subscript(key: String) -> RemoteConfigValue {
        RemoteConfigValue(rawValue: configValues[key])
    }

    /// Returns the wrapped value for `key`.
    public func value(forKey key: String) -> RemoteConfigValue {
        self[key]
    }

    /// The `Bool` value for `key` (default `false`).
    public func bool(_ key: String) -> Bool { self[key].boolValue }

    /// The `String` value for `key`, or `nil`.
    public func string(_ key: String) -> String? { self[key].stringValue }

    /// The `Int` value for `key` (default `0`).
    public func int(_ key: String) -> Int { self[key].intValue }

    /// The `Double` value for `key` (default `0`).
    public func double(_ key: String) -> Double { self[key].doubleValue }

    /// The `NSNumber` value for `key` (default `0`).
    public func number(_ key: String) -> NSNumber { self[key].numberValue }

    /// The `[String: String]` value for `key` (default empty).
    public func stringDictionary(_ key: String) -> [String: String] {
        self[key].stringDictionaryValue ?? [:]
    }

    /// The `[String]` value for `key` (default empty).
    public func stringArray(_ key: String) -> [String] {
        self[key].stringArrayValue ?? []
    }

    /// Decodes the structured value for `key` into a `Decodable` type, or `nil`.
    public func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        self[key].decoded(as: type)
    }
}
