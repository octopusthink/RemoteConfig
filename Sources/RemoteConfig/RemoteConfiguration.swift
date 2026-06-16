//
//  RemoteConfiguration.swift
//  RemoteConfig
//

import Foundation

/**
 Describes where ``RemoteConfig`` should load its baseline (default) values
 from before any remote fetch occurs.

 These defaults ship inside your app/bundle and guarantee that every key has a
 sensible value even when the device is offline or the remote endpoint is
 unreachable.
 */
public enum DefaultsSource: Sendable {
    /// No bundled defaults. Configuration starts empty until a remote fetch
    /// (or cached overrides) populate it.
    case none

    /// Raw JSON `Data` containing a top-level object.
    case data(Data)

    /// A file URL pointing at a JSON document on disk.
    case fileURL(URL)

    /// A resource within a `Bundle` (defaults to `remote-config.json`).
    ///
    /// Use this from an app to load a JSON file you've added to your target,
    /// e.g. `.bundle(.main, resource: "remote-config", extension: "json")`.
    case bundle(Bundle, resource: String, extension: String)
}

/**
 Configuration passed to ``RemoteConfig/configure(_:)`` at app launch.

 All properties have sensible defaults, so the smallest useful configuration is
 just a remote URL and a defaults source:

 ```swift
 RemoteConfig.configure(
     RemoteConfiguration(
         remoteURL: URL(string: "https://example.com/remote-config.json"),
         defaults: .bundle(.main, resource: "remote-config", extension: "json")
     )
 )
 ```
 */
public struct RemoteConfiguration: @unchecked Sendable {
    // `@unchecked` because `UserDefaults` is documented as thread-safe but is
    // not marked `Sendable` by Foundation. Every other stored property is
    // already `Sendable`.
    /// The endpoint polled for updated configuration. When `nil`, only bundled
    /// defaults and previously cached overrides are used.
    public var remoteURL: URL?

    /// Where baseline default values are loaded from on launch.
    public var defaults: DefaultsSource

    /// How often the background task attempts a refresh. Defaults to 6 hours.
    public var refreshInterval: TimeInterval

    /// The minimum elapsed time between successful network fetches. Fetches
    /// requested sooner are skipped unless forced. Defaults to 48 hours.
    public var minimumFetchInterval: TimeInterval

    /// Whether ``RemoteConfig/configure(_:)`` should immediately start the
    /// periodic background refresh task. Defaults to `true`.
    public var automaticallyStartUpdates: Bool

    /// The store used to persist remote overrides between launches.
    /// Defaults to `.standard`.
    public var userDefaults: UserDefaults

    /// Prefix applied to the keys used for cached storage, allowing multiple
    /// instances (or apps sharing a suite) to coexist.
    public var storageKeyPrefix: String

    /// Optional hook returning the host app's current build number.
    ///
    /// When provided and the returned build number is greater than the one
    /// recorded at the last cache write, the cached overrides are discarded so
    /// that freshly-shipped bundled defaults take precedence. Return `nil` to
    /// skip build-number invalidation. Defaults to ``defaultBuildNumberProvider``.
    public var buildNumberProvider: (@Sendable () -> Int?)?

    /// Creates a configuration.
    public init(
        remoteURL: URL? = nil,
        defaults: DefaultsSource = .none,
        refreshInterval: TimeInterval = 6 * 60 * 60,
        minimumFetchInterval: TimeInterval = 48 * 60 * 60,
        automaticallyStartUpdates: Bool = true,
        userDefaults: UserDefaults = .standard,
        storageKeyPrefix: String = "com.remoteconfig",
        buildNumberProvider: (@Sendable () -> Int?)? = RemoteConfiguration.defaultBuildNumberProvider
    ) {
        self.remoteURL = remoteURL
        self.defaults = defaults
        self.refreshInterval = refreshInterval
        self.minimumFetchInterval = minimumFetchInterval
        self.automaticallyStartUpdates = automaticallyStartUpdates
        self.userDefaults = userDefaults
        self.storageKeyPrefix = storageKeyPrefix
        self.buildNumberProvider = buildNumberProvider
    }

    /// Reads `CFBundleVersion` from `Bundle.main` and returns it as an `Int`,
    /// or `nil` when unavailable (e.g. in test/package contexts). Safe on all
    /// platforms.
    public static let defaultBuildNumberProvider: @Sendable () -> Int? = {
        guard
            let raw = Bundle.main.infoDictionary?[kCFBundleVersionKey as String] as? String,
            let value = Int(raw)
        else {
            return nil
        }
        return value
    }
}
