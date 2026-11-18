// swift-tools-version: 6.0
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import PackageDescription
let package = Package(name: "S2ArmControllers", platforms: [.macOS(.v13)],
    products: [.library(name: "S2ArmControllers", targets: ["S2ArmControllers"])],
    targets: [.target(name: "S2ArmControllers", path: ".", exclude: ["Package.swift", "README.md", "mng", "mng_adapter.h", "mng_adapter.m", "mng_ownership.c", "mng_settings.h", "mng_settings.m", "mng_host.m"],
                      publicHeadersPath: "include",
                      linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("GameController"), .linkedFramework("IOKit")])])
