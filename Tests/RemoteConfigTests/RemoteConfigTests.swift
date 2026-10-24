//
//  RemoteConfigTests.swift
//  RemoteConfig
//

import Foundation
import Testing
@testable import RemoteConfig

// MARK: - RemoteConfigValue

@Suite struct RemoteConfigValueTests {
    @Test func boolCoercion() {
        #expect(RemoteConfigValue(rawValue: true).boolValue == true)
        #expect(RemoteConfigValue(rawValue: false).boolValue == false)
        #expect(RemoteConfigValue(rawValue: "true").boolValue == true)
        #expect(RemoteConfigValue(rawValue: "YES").boolValue == true)
        #expect(RemoteConfigValue(rawValue: "1").boolValue == true)
        #expect(RemoteConfigValue(rawValue: "nope").boolValue == false)
        #expect(RemoteConfigValue(rawValue: 1).boolValue == true)
        #expect(RemoteConfigValue(rawValue: 0).boolValue == false)
        #expect(RemoteConfigValue(rawValue: nil).boolValue == false)
    }

    @Test func numberCoercion() {
        #expect(RemoteConfigValue(rawValue: 1.75).doubleValue == 1.75)
        #expect(RemoteConfigValue(rawValue: 42).intValue == 42)
        #expect(RemoteConfigValue(rawValue: "3.5").doubleValue == 3.5)
        #expect(RemoteConfigValue(rawValue: "not a number").intValue == 0)
        #expect(RemoteConfigValue(rawValue: nil).intValue == 0)
    }

    @Test func stringCoercion() {
        #expect(RemoteConfigValue(rawValue: "hello").stringValue == "hello")
        #expect(RemoteConfigValue(rawValue: 42).stringValue == "42")
        #expect(RemoteConfigValue(rawValue: nil).stringValue == nil)
    }

    @Test func collectionAccessors() {
        let dict = RemoteConfigValue(rawValue: ["a": "1", "b": "2"])
        #expect(dict.stringDictionaryValue == ["a": "1", "b": "2"])

        let array = RemoteConfigValue(rawValue: ["x", "y"])
        #expect(array.stringArrayValue == ["x", "y"])

        #expect(RemoteConfigValue(rawValue: "scalar").stringDictionaryValue == nil)
    }

    struct Endpoints: Codable, Equatable {
        let api: String
        let support: String
    }

    @Test func decodeStructured() {
        let value = RemoteConfigValue(rawValue: [
            "api": "https://api.example.com",
            "support": "https://example.com/support",
        ])
        let decoded = value.decoded(as: Endpoints.self)
        #expect(decoded == Endpoints(api: "https://api.example.com", support: "https://example.com/support"))
    }
}

// MARK: - RemoteConfig

@MainActor
@Suite struct RemoteConfigTests {
    /// A fresh, isolated instance backed by a scratch UserDefaults suite so tests
    /// never touch `.standard` or each other.
    private func makeConfig(
        defaults: DefaultsSource,
        suite: String,
        remoteURL: URL? = nil,
        buildNumberProvider: (@Sendable () -> Int?)? = nil
    ) -> RemoteConfig {
        let userDefaults = UserDefaults(suiteName: suite)!
        userDefaults.removePersistentDomain(forName: suite)

        let config = RemoteConfig()
        config.apply(
            RemoteConfiguration(
                remoteURL: remoteURL,
                defaults: defaults,
                automaticallyStartUpdates: false,
                userDefaults: userDefaults,
                storageKeyPrefix: "test",
                buildNumberProvider: buildNumberProvider
            )
        )
        return config
    }

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func loadsBundledDefaultsFromData() {
        let config = makeConfig(
            defaults: .data(json(["featureFlagEnabled": true, "name": "Test"])),
            suite: "test.defaults"
        )

        #expect(config.bool("featureFlagEnabled") == true)
        #expect(config.string("name") == "Test")
        #expect(config["featureFlagEnabled"].boolValue == true)
    }

    @Test func loadsExampleResourceFromModuleBundle() {
        let config = makeConfig(
            defaults: .bundle(.module, resource: "remote-config.example", extension: "json"),
            suite: "test.resource"
        )

        #expect(config.bool("featureFlagEnabled") == true)
        #expect(config.string("welcomeMessage") == "Hello from RemoteConfig!")
        #expect(config.stringArray("supportedRegions").contains("jp"))
    }

    @Test func missingKeysReturnDefaults() {
        let config = makeConfig(defaults: .none, suite: "test.empty")

        #expect(config.bool("nope") == false)
        #expect(config.int("nope") == 0)
        #expect(config.string("nope") == nil)
        #expect(config.stringDictionary("nope").isEmpty)
    }

    @Test func cachedOverridesTakePrecedenceOverDefaults() {
        let suite = "test.cache"
        let userDefaults = UserDefaults(suiteName: suite)!
        userDefaults.removePersistentDomain(forName: suite)

        // Pre-seed a cached override that disagrees with the bundled default.
        userDefaults.set(json(["featureFlagEnabled": false]), forKey: "test.cachedData")

        let config = RemoteConfig()
        config.apply(
            RemoteConfiguration(
                defaults: .data(json(["featureFlagEnabled": true, "extra": 1])),
                automaticallyStartUpdates: false,
                userDefaults: userDefaults,
                storageKeyPrefix: "test",
                buildNumberProvider: nil
            )
        )

        // Cache wins for overlapping keys, defaults remain for the rest.
        #expect(config.bool("featureFlagEnabled") == false)
        #expect(config.int("extra") == 1)
    }

    @Test func newerBuildNumberInvalidatesCache() {
        let suite = "test.build"
        let userDefaults = UserDefaults(suiteName: suite)!
        userDefaults.removePersistentDomain(forName: suite)

        // Stale cache recorded under an older build number.
        userDefaults.set(json(["featureFlagEnabled": false]), forKey: "test.cachedData")
        userDefaults.set(10, forKey: "test.buildNumber")

        let config = RemoteConfig()
        config.apply(
            RemoteConfiguration(
                defaults: .data(json(["featureFlagEnabled": true])),
                automaticallyStartUpdates: false,
                userDefaults: userDefaults,
                storageKeyPrefix: "test",
                buildNumberProvider: { 20 } // newer build
            )
        )

        // Cache discarded, bundled default wins, build number advanced.
        #expect(config.bool("featureFlagEnabled") == true)
        #expect(userDefaults.data(forKey: "test.cachedData") == nil)
        #expect(userDefaults.integer(forKey: "test.buildNumber") == 20)
    }

    @Test func decodeStructuredValue() {
        struct Endpoints: Codable, Equatable {
            let api: String
        }

        let config = makeConfig(
            defaults: .data(json(["endpoints": ["api": "https://api.example.com"]])),
            suite: "test.decode"
        )

        #expect(config.decode(Endpoints.self, forKey: "endpoints") == Endpoints(api: "https://api.example.com"))
    }

    @Test func fetchIsThrottledUntilIntervalElapses() async {
        let suite = "test.throttle"
        let userDefaults = UserDefaults(suiteName: suite)!
        userDefaults.removePersistentDomain(forName: suite)

        // Record a very recent successful fetch.
        userDefaults.set(Date().timeIntervalSince1970, forKey: "test.lastUpdated")

        let config = RemoteConfig()
        config.apply(
            RemoteConfiguration(
                remoteURL: URL(string: "https://example.invalid/remote-config.json"),
                defaults: .data(json(["featureFlagEnabled": true])),
                minimumFetchInterval: 3600,
                automaticallyStartUpdates: false,
                userDefaults: userDefaults,
                storageKeyPrefix: "test",
                buildNumberProvider: nil
            )
        )

        let before = userDefaults.double(forKey: "test.lastUpdated")
        // Should return immediately without attempting a network request.
        await config.fetchRemoteUpdates()
        let after = userDefaults.double(forKey: "test.lastUpdated")

        #expect(before == after)
    }

    // MARK: Remote fetches

    /// Writes `object` to a temporary file and returns its URL, so fetches can
    /// be exercised via `URLSession` without hitting the network.
    private func remoteFile(_ object: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-config-\(UUID().uuidString).json")
        try json(object).write(to: url)
        return url
    }

    @Test func fetchMergesRemoteValuesAndPersistsCache() async throws {
        let suite = "test.fetch"
        let remoteURL = try remoteFile(["featureFlagEnabled": false, "remoteOnly": "hi"])
        defer { try? FileManager.default.removeItem(at: remoteURL) }

        let config = makeConfig(
            defaults: .data(json(["featureFlagEnabled": true, "extra": 1])),
            suite: suite,
            remoteURL: remoteURL
        )
        await config.fetchRemoteUpdates()

        // Remote values override defaults; untouched defaults remain.
        #expect(config.bool("featureFlagEnabled") == false)
        #expect(config.string("remoteOnly") == "hi")
        #expect(config.int("extra") == 1)

        let userDefaults = UserDefaults(suiteName: suite)!
        #expect(userDefaults.data(forKey: "test.cachedData") != nil)
        #expect(userDefaults.double(forKey: "test.lastUpdated") > 0)

        // A fresh instance picks up the cached overrides without fetching.
        let relaunched = RemoteConfig()
        relaunched.apply(
            RemoteConfiguration(
                defaults: .data(json(["featureFlagEnabled": true])),
                automaticallyStartUpdates: false,
                userDefaults: userDefaults,
                storageKeyPrefix: "test",
                buildNumberProvider: nil
            )
        )
        #expect(relaunched.bool("featureFlagEnabled") == false)
        #expect(relaunched.string("remoteOnly") == "hi")
    }

    @Test func forcedFetchBypassesThrottle() async throws {
        let suite = "test.force"
        let remoteURL = try remoteFile(["featureFlagEnabled": false])
        defer { try? FileManager.default.removeItem(at: remoteURL) }

        let config = makeConfig(
            defaults: .data(json(["featureFlagEnabled": true])),
            suite: suite,
            remoteURL: remoteURL
        )
        // Pretend a fetch just succeeded, so an unforced fetch is throttled.
        UserDefaults(suiteName: suite)!.set(Date().timeIntervalSince1970, forKey: "test.lastUpdated")

        await config.fetchRemoteUpdates()
        #expect(config.bool("featureFlagEnabled") == true)

        await config.fetchRemoteUpdates(forceUpdate: true)
        #expect(config.bool("featureFlagEnabled") == false)
    }

    @Test func invalidRemotePayloadKeepsExistingValues() async throws {
        let suite = "test.invalid"
        let remoteURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-config-\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: remoteURL)
        defer { try? FileManager.default.removeItem(at: remoteURL) }

        let config = makeConfig(
            defaults: .data(json(["featureFlagEnabled": true])),
            suite: suite,
            remoteURL: remoteURL
        )
        await config.fetchRemoteUpdates(forceUpdate: true)

        #expect(config.bool("featureFlagEnabled") == true)
        #expect(UserDefaults(suiteName: suite)!.double(forKey: "test.lastUpdated") == 0)
    }

    // MARK: Periodic updates

    @Test func startingPeriodicUpdatesAgainReplacesTheExistingLoop() throws {
        let config = makeConfig(defaults: .none, suite: "test.periodic")

        config.startPeriodicUpdates()
        let first = try #require(config.updateTask)

        // Repeated calls (eg. from a Debug menu) must not stack loops, but
        // must also leave updates running.
        config.startPeriodicUpdates()
        let second = try #require(config.updateTask)

        #expect(first.isCancelled)
        #expect(!second.isCancelled)
        #expect(first != second)

        config.stopPeriodicUpdates()
        #expect(second.isCancelled)
        #expect(config.updateTask == nil)
    }

    @Test func applyStartsUpdatesOnlyWhenEnabledWithRemoteURL() {
        let suite = "test.autostart"
        let userDefaults = UserDefaults(suiteName: suite)!
        userDefaults.removePersistentDomain(forName: suite)
        // Throttle fetches so the started loop never touches the network.
        userDefaults.set(Date().timeIntervalSince1970, forKey: "test.lastUpdated")

        let config = RemoteConfig()
        config.apply(
            RemoteConfiguration(
                remoteURL: URL(string: "https://example.invalid/remote-config.json"),
                userDefaults: userDefaults,
                storageKeyPrefix: "test",
                buildNumberProvider: nil
            )
        )
        #expect(config.updateTask != nil)

        config.apply(RemoteConfiguration(userDefaults: userDefaults, storageKeyPrefix: "test"))
        #expect(config.updateTask == nil)
    }

    // MARK: Typed value cache

    @Test func typedValuesAreInvalidatedWhenConfigChanges() async throws {
        let suite = "test.typedCache"
        let remoteURL = try remoteFile([
            "regions": ["fr"],
            "devices": ["b": "2"],
        ])
        defer { try? FileManager.default.removeItem(at: remoteURL) }

        let config = makeConfig(
            defaults: .data(json(["regions": ["us", "ca"], "devices": ["a": "1"]])),
            suite: suite,
            remoteURL: remoteURL
        )

        // Populate the cache.
        #expect(config.stringArray("regions") == ["us", "ca"])
        #expect(config.stringDictionary("devices") == ["a": "1"])

        await config.fetchRemoteUpdates(forceUpdate: true)

        #expect(config.stringArray("regions") == ["fr"])
        #expect(config.stringDictionary("devices") == ["b": "2"])
    }

    @Test func typedValuesHandleMismatchedTypesForTheSameKey() {
        let config = makeConfig(
            defaults: .data(json(["regions": ["us", "ca"]])),
            suite: "test.typedMismatch"
        )

        #expect(config.stringArray("regions") == ["us", "ca"])
        // Asking for a different type must not return the cached array.
        #expect(config.stringDictionary("regions").isEmpty)
        // ...and asking for the original type again still works.
        #expect(config.stringArray("regions") == ["us", "ca"])
        #expect(config.stringArray("missing").isEmpty)
    }

    @Test func cachedTypedValuesStillTriggerObservation() async throws {
        let remoteURL = try remoteFile(["regions": ["fr"]])
        defer { try? FileManager.default.removeItem(at: remoteURL) }

        let config = makeConfig(
            defaults: .data(json(["regions": ["us"]])),
            suite: "test.typedObservation",
            remoteURL: remoteURL
        )
        // Warm the cache so the tracked read below is a cache hit.
        _ = config.stringArray("regions")

        let changed = ChangeFlag()
        withObservationTracking {
            _ = config.stringArray("regions")
        } onChange: {
            changed.fired = true
        }

        await config.fetchRemoteUpdates(forceUpdate: true)
        #expect(changed.fired)
    }
}

private final class ChangeFlag: @unchecked Sendable {
    var fired = false
}
