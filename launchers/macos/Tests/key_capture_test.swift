// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
@main struct KeyCaptureTest {
    static func main() {
        var capture = InputKeyCapture()
        func check(_ value: Bool, _ why: String) { if !value { fatalError(why) } }
        check(capture.event(code: 56, modifiers: 1, flagsChanged: true) == nil, "Shift down must wait for chord or release")
        check(capture.event(code: 14, modifiers: 1, flagsChanged: false) == .bind(code: 14, modifiers: 1), "Shift E chord")
        capture.reset()
        check(capture.event(code: 62, modifiers: 2, flagsChanged: true) == nil, "right Ctrl waits")
        check(capture.event(code: 62, modifiers: 0, flagsChanged: true) == .bind(code: 59, modifiers: 0), "standalone Ctrl on release")
        capture.reset()
        check(capture.event(code: 56, modifiers: 1, flagsChanged: true) == nil, "wait")
        check(capture.event(code: 58, modifiers: 5, flagsChanged: true) == nil, "multiple modifiers wait")
        check(capture.event(code: 0, modifiers: 5, flagsChanged: false) == .bind(code: 0, modifiers: 5), "Shift Option A")
        capture.reset()
        check(capture.event(code: 0, modifiers: 0, flagsChanged: false, repeatKey: true) == nil, "ignore repeat")
        check(capture.event(code: 0, modifiers: 0, flagsChanged: false, command: true) == nil, "ignore Cmd")
        check(capture.event(code: 53, modifiers: 0, flagsChanged: false) == .cancel, "escape cancels")
        capture.reset()
        check(capture.event(code: 56, modifiers: 0, flagsChanged: true) == nil, "orphan release ignored")
        print("Key capture: chord, standalone modifier, right modifier, repeats, command, cancel and reset passed")
    }
}
