import XCTest
@testable import PortStudio

/// Controller states turned into Library keys, with synthetic states and times; no
/// controller is needed.
final class LibraryControllerTests: XCTestCase {
    func testTheStrongerAxisWinsAndARestingStickSendsNothing() {
        XCTAssertNil(LibraryPadState.direction(x: 0.3, y: -0.4))
        XCTAssertEqual(LibraryPadState.direction(x: -0.9, y: 0.2), .left)
        XCTAssertEqual(LibraryPadState.direction(x: 0.6, y: 0.1), .right)
        XCTAssertEqual(LibraryPadState.direction(x: 0.2, y: 0.8), .up)      // the stick's y grows upward
        XCTAssertEqual(LibraryPadState.direction(x: -0.5, y: -0.7), .down)
    }

    func testAHeldDirectionRepeatsLikeAHeldKey() {
        var pad = LibraryPadRepeater()
        let right = LibraryPadState(direction: .right)
        XCTAssertEqual(pad.step(right, at: 0), [.right])
        XCTAssertEqual(pad.step(right, at: 0.2), [])          // before the delay
        XCTAssertEqual(pad.step(right, at: 0.4), [.right])
        XCTAssertEqual(pad.step(right, at: 0.45), [])
        XCTAssertEqual(pad.step(right, at: 0.53), [.right])   // then every interval
        XCTAssertEqual(pad.step(LibraryPadState(direction: .down), at: 0.54), [.down])   // a new direction sends at once
        XCTAssertEqual(pad.step(LibraryPadState(), at: 0.6), [])
        XCTAssertEqual(pad.step(right, at: 0.61), [.right])
    }

    func testButtonsSendOnceWhenTheyGoDown() {
        var pad = LibraryPadRepeater()
        XCTAssertEqual(pad.step(LibraryPadState(activate: true), at: 0), [.activate])
        XCTAssertEqual(pad.step(LibraryPadState(activate: true), at: 1), [])
        XCTAssertEqual(pad.step(LibraryPadState(), at: 1.1), [])
        XCTAssertEqual(pad.step(LibraryPadState(alternate: true, back: true, fullScreen: true), at: 1.2), [.alternate, .back, .fullScreen])
    }
}
