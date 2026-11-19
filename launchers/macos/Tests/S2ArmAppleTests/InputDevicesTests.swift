// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import XCTest
@testable import NX2AppleUI

final class InputDevicesTests: XCTestCase {
    func testFourPlayerSelectionsSurviveUnrelatedMappingEdit() throws {
        var config = InputConfig.standard
        config.players = Dictionary(uniqueKeysWithValues: (1...4).map {
            (String($0), ControllerSelection(backend: "auto", device: ""))
        })
        config.players?["3"] = ControllerSelection(backend: "nspro-hid", device: "hid:fixture")
        let data = try JSONEncoder().encode(config)
        var decoded = try JSONDecoder().decode(InputConfig.self, from: data)
        XCTAssertEqual(decoded.players?.count, 4)
        XCTAssertNil(decoded.controller)
        decoded.keyboard["A"] = KeyBinding(code: 36)
        let again = try JSONDecoder().decode(InputConfig.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(again.players, config.players)
        XCTAssertEqual(again.players?["1"]?.backend, "auto")
        XCTAssertEqual(again.players?["3"]?.device, "hid:fixture")
    }

    func testLegacyAndSelectedDeviceRoundTrip() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var config = InputConfig.standard
        let old = try encoder.encode(config)
        XCTAssertNil(try decoder.decode(InputConfig.self, from: old).controller)
        config.controller = ControllerSelection(backend: "nspro-hid", device: "hid:123")
        XCTAssertEqual(try decoder.decode(InputConfig.self, from: encoder.encode(config)), config)
    }
    func testModifierChordAndStandaloneRelease() {
        var c = InputKeyCapture()
        XCTAssertNil(c.event(code: 56, modifiers: 1, flagsChanged: true))
        XCTAssertEqual(c.event(code: 14, modifiers: 1, flagsChanged: false), .bind(code: 14, modifiers: 1))
        XCTAssertNil(c.event(code: 56, modifiers: 0, flagsChanged: true))
        XCTAssertNil(c.event(code: 62, modifiers: 2, flagsChanged: true))
        XCTAssertEqual(c.event(code: 62, modifiers: 0, flagsChanged: true), .bind(code: 59, modifiers: 0))
        XCTAssertNil(c.event(code: 58, modifiers: 4, flagsChanged: true))
        c.reset()
        XCTAssertNil(c.event(code: 58, modifiers: 0, flagsChanged: true))
        XCTAssertNil(c.event(code: 0, modifiers: 0, flagsChanged: false, repeatKey: true))
        XCTAssertNil(c.event(code: 0, modifiers: 0, flagsChanged: false, command: true))
        XCTAssertEqual(c.event(code: 53, modifiers: 0, flagsChanged: false), .cancel)
    }
    func testCaptureStillReportsDuplicateMappings() {
        var c = InputConfig.standard
        c.gamepad["B"] = c.gamepad["A"]
        XCTAssertTrue(c.conflictingTargets.contains("A"))
        XCTAssertTrue(c.conflictingTargets.contains("B"))
        c.restoreTarget("B", from: .standard)
        XCTAssertTrue(c.conflicts.isEmpty)
    }
}
