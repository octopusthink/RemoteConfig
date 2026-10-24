# RemoteConfig

Dependency-free remote configuration / feature-flag loader for iOS, iPadOS, macOS, tvOS, watchOS, and visionOS.

`RemoteConfig` ships baseline defaults inside your app, then periodically fetches
an updated JSON document from an endpoint you specify.

This was created to replace [Mic Drop](https://getmicdrop.com)'s usage of
Firebase's `RemoteConfig`, so there is some similarities in the access approach.

- Zero third-party dependencies (pure Foundation + Observation)
- Synchronous, offline-safe defaults loaded on launch
- Cached remote overrides that survive relaunches
- Background refresh on a configurable interval
- `@Observable` — SwiftUI views update automatically on refresh
- One shared singleton: `RemoteConfig.shared`

## Requirements

| Platform | Minimum |
| --- | --- |
| iOS / iPadOS | 17.0 |
| macOS | 14.0 |
| tvOS | 17.0 |
| watchOS | 10.0 |
| visionOS | 1.0 |

## Installation

### Swift Package Manager

Add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/octpusthink/RemoteConfig.git", from: "1.0.0")
]
```

Or in Xcode: **File ▸ Add Package Dependencies…** and paste the repository URL:
`https://github.com/octpusthink/RemoteConfig.git`.

Then `import RemoteConfig`.

## Quick start

### 1. Add a defaults file to your app

Bundle a `remote-config.json` in your app target. It must be a single JSON
object. (See [`remote-config.example.json`](Sources/RemoteConfig/Resources/remote-config.example.json)
for a sample.)

```json
{
    "featureFlagEnabled": true,
    "welcomeMessage": "Hello!",
    "supportedRegions": ["us", "ca", "gb"]
}
```

### 2. Configure once at launch

```swift
import RemoteConfig

@main
struct MyApp: App {
    init() {
        RemoteConfig.configure(
            RemoteConfiguration(
                remoteURL: URL(string: "https://example.com/remote-config.json"),
                defaults: .bundle(.main, resource: "remote-config", extension: "json")
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

`configure(_:)` loads the bundled defaults synchronously, merges any cached
remote overrides from a previous run, and starts the background refresh task.

### 3. Read values anywhere

```swift
// Typed accessors:
if RemoteConfig.shared.bool("featureFlagEnabled") {
    // Do other stuff based on the feature flag's existence.
}
let message = RemoteConfig.shared.string("welcomeMessage")
let regions = RemoteConfig.shared.stringArray("supportedRegions")

// Or Firebase-style subscript access, useful if migrating:
let raw = RemoteConfig.shared["welcomeMessage"].stringValue
```

`RemoteConfig` is `@MainActor`-isolated.

## SwiftUI

Because `RemoteConfig` is `@Observable`, SwiftUI views re-render when a remote
refresh changes a value:

```swift
struct ContentView: View {
    var newOnboardingEnabled = RemoteConfig.shared.bool("newOnboardingEnabled")
    var body: some View {
        if newOnboardingEnabled {
            NewOnboardingView()
        } else {
            ClassicOnboardingView()
        }
    }
}
```

## Typed accessors

You can add a typed extension in your own target. This is how Mic Drop uses
remote config values:

```swift
import RemoteConfig

extension RemoteConfig {
    var ignoredDevices: [String: String] { stringDictionary("ignoredDevices") }
    var useWebSocketServer: Bool { bool("useWebSocketServer") }
    var cannotMuteNotificationTime: Double { double("cannotMuteNotificationTime") }
    var builtInMicrophoneNames: [String] { stringArray("builtInMicrophoneNames") }
}

// Usage:
let devices = RemoteConfig.shared.ignoredDevices
```

For structured values, decode into your own `Codable` models:

```swift
struct Endpoints: Codable { let api: String; let support: String }

let endpoints = RemoteConfig.shared.decode(Endpoints.self, forKey: "endpoints")
```

## How it works

Values are resolved by merging three layers, each overriding the previous:

1. **Bundled defaults** — loaded synchronously on launch from your
   `DefaultsSource` (`.bundle`, `.fileURL`, `.data`, or `.none`). Always
   available, even offline.
2. **Cached overrides** — the last successfully fetched remote payload,
   persisted in `UserDefaults` between launches.
3. **Remote payload** — fetched in the background from `remoteURL`.

Refresh behaviour is controlled by `RemoteConfiguration`:

- `refreshInterval` — how often the background task wakes to refresh (default: **12 hours**).
- `minimumFetchInterval` — the throttle between successful network fetches
  (default: **48 hours**). `fetchRemoteUpdates(forceUpdate: true)` bypasses it.
- `buildNumberProvider` — when you ship a new build (a higher `CFBundleVersion`),
  cached overrides are discarded so freshly-bundled defaults are used.
  Pass `nil` to disable this behaviour.

You can also trigger refreshes manually:

```swift
await RemoteConfig.shared.fetchRemoteUpdates(forceUpdate: true)
```

## Configuration reference

| Property | Default | Description |
| --- | --- | --- |
| `remoteURL` | `nil` | Endpoint polled for updates. `nil` = defaults + cache only. |
| `defaults` | `.none` | Where baseline values come from. |
| `refreshInterval` | 12 hours | Background refresh cadence. |
| `minimumFetchInterval` | 48 hours | Throttle between successful fetches. |
| `automaticallyStartUpdates` | `true` | Start the background task on `configure`. |
| `userDefaults` | `.standard` | Store used for cached overrides. |
| `storageKeyPrefix` | `"com.remoteconfig"` | Prefix for cache keys. |
| `buildNumberProvider` | reads `CFBundleVersion` | Cache invalidation hook. |

## License

MIT © 2026 Octopus Think. See [LICENSE](LICENSE.txt).
