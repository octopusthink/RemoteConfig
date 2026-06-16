// swift-tools-version: 6.0
//
//  Package.swift
//  RemoteConfig
//

import PackageDescription

let package = Package(
    name: "RemoteConfig",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "RemoteConfig",
            targets: ["RemoteConfig"]
        ),
    ],
    targets: [
        .target(
            name: "RemoteConfig",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "RemoteConfigTests",
            dependencies: ["RemoteConfig"]
        ),
    ]
)
