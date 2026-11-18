// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import Combine
import S2ArmControllers

@MainActor final class ControllerMonitor: ObservableObject {
    @Published var devices: [[String: String]] = []
    @Published var values: [String: NSNumber] = [:]
    @Published var status = ""
    private let input = S2AControllerInput()
    private var timer: Timer?
    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }
    func configure(_ selection: ControllerSelection?) {
        let s = selection ?? ControllerSelection()
        input.configureBackend(s.backend, device: s.device)
        poll()
    }
    private func poll() {
        devices = input.devices
        values = NSApp.isActive ? input.snapshot : [:]
        status = input.status
    }
    func stop() { timer?.invalidate(); timer = nil; input.stop(); values = [:] }
    deinit { timer?.invalidate() }
}
