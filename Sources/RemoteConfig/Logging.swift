//
//  Logging.swift
//  RemoteConfig
//

import Foundation

#if canImport(os)
import os
#endif

/// Internal, cross-platform logging shim.
///
/// Uses the unified logging system (`os.Logger`) where available and falls back
/// to `print` on platforms that don't ship `os`. Replaces the Darwin-only
/// `NSLog` used by the original implementation.
enum RemoteConfigLog {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.remoteconfig", category: "RemoteConfig")
    #endif

    static func info(_ message: @autoclosure @escaping () -> String) {
        #if canImport(os)
        logger.info("\(message(), privacy: .public)")
        #else
        print("[RemoteConfig] \(message())")
        #endif
    }

    static func error(_ message: @autoclosure @escaping () -> String) {
        #if canImport(os)
        logger.error("\(message(), privacy: .public)")
        #else
        print("[RemoteConfig] ERROR: \(message())")
        #endif
    }
}
