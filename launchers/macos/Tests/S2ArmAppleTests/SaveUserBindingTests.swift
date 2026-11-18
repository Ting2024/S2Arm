import Foundation
import XCTest
@testable import NX2AppleUI

final class SaveUserBindingTests: XCTestCase {
    private var response: [String: Any] {
        ["manifest": ["game": ["name": "Fixture", "version": 1]],
         "archiveSha256": String(repeating: "a", count: 64),
         "targetFingerprint": String(repeating: "b", count: 64),
         "previewLibraryId": "fixture-library"]
    }

    func testBindingIsCapturedAndMalformedBindingIsNotSilentlyDropped() throws {
        let source = URL(fileURLWithPath: "/synthetic/save.zip")
        let binding = String(repeating: "c", count: 64)
        var body = response
        body["previewUserBinding"] = binding
        let preview = try XCTUnwrap(SavePreviewInfo(body, source: source))
        XCTAssertEqual(preview.previewUserBinding, binding)
        XCTAssertEqual(preview.restoreRequest["previewUserBinding"] as? String, binding)
        XCTAssertEqual(preview.restoreRequest["path"] as? String, source.path)
        XCTAssertNil(preview.restoreRequest["notice"])
        for invalid: Any in ["", "01", String(repeating: "C", count: 64), 1, NSNull()] {
            body["previewUserBinding"] = invalid
            XCTAssertNil(SavePreviewInfo(body, source: source))
        }
        XCTAssertNil(try XCTUnwrap(SavePreviewInfo(response, source: source)).previewUserBinding)
    }
}
