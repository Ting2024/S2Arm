import XCTest
@testable import NX2AppleUI

final class OperationConflictTests: XCTestCase {
    func testMatrixIsSymmetricAndBrowsingNeverBlocks() {
        for left in OperationIntent.Kind.allCases {
            for right in OperationIntent.Kind.allCases {
                let a = OperationIntent(kind: left, gameID: "A", userID: "01", deviceID: "phone1")
                let b = OperationIntent(kind: right, gameID: "B", userID: "02", deviceID: "phone2")
                XCTAssertEqual(a.conflicts(with: b), b.conflicts(with: a))
                XCTAssertFalse(a.conflicts(with: OperationIntent(kind: .browse)))
            }
        }
    }
    func testPhoneOperationsDoNotOwnMacUserState() {
        for phone in [OperationIntent.Kind.transfer, .installHost, .removeFromPhone] {
            for local in [OperationIntent.Kind.play, .saves] {
                XCTAssertFalse(OperationIntent(kind: phone, gameID: "A").conflicts(with:
                    OperationIntent(kind: local, gameID: "A", userID: "01")))
            }
        }
    }
    func testSamePairConflictsDifferentPairDoesNot() {
        let save = OperationIntent(kind: .saves, gameID: "a", userID: "01")
        XCTAssertTrue(save.conflicts(with: OperationIntent(kind: .play, gameID: "A", userID: "01")))
        XCTAssertFalse(save.conflicts(with: OperationIntent(kind: .play, gameID: "A", userID: "02")))
        XCTAssertFalse(save.conflicts(with: OperationIntent(kind: .saves, gameID: "B", userID: "01")))
        XCTAssertTrue(save.conflicts(with: OperationIntent(kind: .play, gameID: "A")))
    }
    func testBuildersAndUnreviewedMutationsRemainProtected() {
        let play = OperationIntent(kind: .play, gameID: "A", userID: "01")
        XCTAssertTrue(play.conflicts(with: OperationIntent(kind: .build, gameID: "A")))
        XCTAssertFalse(play.conflicts(with: OperationIntent(kind: .build, gameID: "B")))
        for kind in [OperationIntent.Kind.importGames, .deleteGame, .changeLibrary, .changeTools] {
            XCTAssertTrue(play.conflicts(with: OperationIntent(kind: kind, gameID: "B")))
        }
        // Device-scoped protection prevents concurrent phone operations, while
        // phone operations on game A can run alongside building game B.
        XCTAssertTrue(OperationIntent(kind: .transfer, gameID: "A", deviceID: "one").conflicts(with:
            OperationIntent(kind: .installHost, gameID: "B", deviceID: "one")))
        XCTAssertTrue(OperationIntent(kind: .transfer, gameID: "B").conflicts(with: OperationIntent(kind: .build, gameID: "B")))
        XCTAssertFalse(OperationIntent(kind: .transfer, gameID: "A").conflicts(with: OperationIntent(kind: .build, gameID: "B")))
        XCTAssertFalse(OperationIntent(kind: .installHost, gameID: "A").conflicts(with: OperationIntent(kind: .build, gameID: "B")))
        XCTAssertTrue(OperationIntent(kind: .transfer).conflicts(with: OperationIntent(kind: .build, gameID: "B")))
    }
}
