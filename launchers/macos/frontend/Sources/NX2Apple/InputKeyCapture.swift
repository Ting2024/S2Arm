// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Pure state machine; nil means keep recording. Escape emits a cancellation.
struct InputKeyCapture {
    enum Result: Equatable { case bind(code: Int, modifiers: Int), cancel }
    private var pending: Int?
    mutating func reset() { pending = nil }
    mutating func event(code: Int, modifiers: Int, flagsChanged: Bool, repeatKey: Bool = false, command: Bool = false) -> Result? {
        let code = [60:56, 62:59, 61:58][code] ?? code
        if command || repeatKey { return nil }
        if flagsChanged {
            let bit = code == 56 ? 1 : code == 59 ? 2 : code == 58 ? 4 : 0
            if bit == 0 { return nil }
            if modifiers & bit != 0 { pending = code; return nil }
            guard pending == code else { return nil }
            pending = nil
            return .bind(code: code, modifiers: 0)
        }
        pending = nil
        return code == 53 ? .cancel : .bind(code: code, modifiers: modifiers)
    }
}
