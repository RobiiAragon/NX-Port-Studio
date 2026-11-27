import Foundation
import XCTest
@testable import PortCore
@testable import PortStudio

/// The Library's keys and friend list, on synthetic ports and friends; no port is opened
/// (Return is never sent on the games row) and the window is never made full screen.
@MainActor
final class LibraryModelTests: XCTestCase {
    private func model() -> StudioModel {
        let preferences = UserDefaults(suiteName: "org.nxnative.tests.library." + UUID().uuidString)!
        let model = StudioModel(nextendoPreferences: preferences)
        let root = URL(fileURLWithPath: "/nonexistent/Applications")
        model.libraryPorts = ["A", "B", "C"].map { name in
            InstalledMacPort(appURL: root.appendingPathComponent(name + ".app"), titleID: "01000000000\(name == "A" ? 1 : name == "B" ? 2 : 3)0000",
                             name: name, bundleIdentifier: "org.example." + name, stateURL: root)
        }
        model.librarySelection = model.libraryPorts.first?.id
        return model
    }

    func testArrowsMoveAlongAndBetweenTheRowsAndStopAtTheEnds() {
        let model = model()
        XCTAssertTrue(model.handleLibraryKey(.left))
        XCTAssertEqual(model.selectedLibraryPort?.name, "A")
        model.handleLibraryKey(.right); model.handleLibraryKey(.right); model.handleLibraryKey(.right)
        XCTAssertEqual(model.selectedLibraryPort?.name, "C")
        XCTAssertFalse(model.handleLibraryKey(.up))            // nothing above the games
        XCTAssertTrue(model.handleLibraryKey(.down))
        XCTAssertEqual(model.libraryRow, .shortcuts)
        XCTAssertFalse(model.handleLibraryKey(.down))
        model.handleLibraryKey(.right); model.handleLibraryKey(.right)
        XCTAssertEqual(model.libraryShortcut, 2)
        XCTAssertEqual(model.selectedLibraryPort?.name, "C")   // the games keep their focus
        for _ in 0..<10 { model.handleLibraryKey(.right) }
        XCTAssertEqual(model.libraryShortcut, LibraryShortcut.allCases.count - 1)
        model.handleLibraryKey(.up)
        XCTAssertEqual(model.libraryRow, .games)
        XCTAssertFalse(model.handleLibraryKey(.back))           // Escape only leaves full screen
    }

    func testShortcutsOpenFriendsAndLeaveForStudioPages() {
        let model = model()
        model.handleLibraryKey(.down)
        XCTAssertTrue(model.handleLibraryKey(.activate))       // the first shortcut: Friends
        XCTAssertEqual(model.libraryScreen, .friends)
        for _ in 0..<5 { model.handleLibraryKey(.down) }
        XCTAssertEqual(model.libraryFriendsSection, .add)
        model.handleLibraryKey(.up); model.handleLibraryKey(.up)
        XCTAssertEqual(model.libraryFriendsSection, .received)
        XCTAssertTrue(model.handleLibraryKey(.back))
        XCTAssertEqual(model.libraryScreen, .home)
        model.page = .library
        model.runLibraryShortcut(.saves)
        XCTAssertEqual(model.page, .saves)
        XCTAssertEqual(model.libraryScreen, .home)
    }

    func testFriendListPutsPlayingThenOnlineFirstAndNamesTheGame() {
        let model = model()
        model.nextendoFriends = NextendoFriendsView(friends: [
            NextendoFriend(pid: 1, name: "zed", status: 0, titleID: nil),
            NextendoFriend(pid: 5, name: "Best", status: 0, titleID: nil, favorite: true),
            NextendoFriend(pid: 2, name: "Amy", status: 0, titleID: nil),
            NextendoFriend(pid: 3, name: "bo", status: 1, titleID: nil),
            NextendoFriend(pid: 4, name: "Cy", status: 2, titleID: "0100000000010000")], requests: [], sent: [])
        model.nextendoGameNames = ["0100000000010000": "Synthetic Game"]
        XCTAssertEqual(model.libraryFriends.map(\.name), ["Best", "Cy", "bo", "Amy", "zed"])   // best friends stay first
        XCTAssertEqual(model.libraryFriendsOnline, 2)
        let english = StudioLocalization.shared.language
        StudioLocalization.shared.language = .english
        defer { StudioLocalization.shared.language = english }
        XCTAssertEqual(model.libraryFriendActivity(model.libraryFriends[1]), "Playing Synthetic Game")
        XCTAssertEqual(model.libraryFriendActivity(model.libraryFriends[2]), "Online")
        XCTAssertEqual(model.libraryFriendActivity(model.libraryFriends[3]), "Offline")
    }

    func testAddFriendChecksTheCodeBeforeAskingTheAgent() async {
        let model = model()
        model.libraryFriendCode = "12-34"
        await model.sendLibraryFriendRequest()
        XCTAssertEqual(model.libraryFriendRequestResult?.sent, false)
        XCTAssertFalse(model.isSendingFriendRequest)
        XCTAssertEqual(model.libraryFriendCode, "12-34")        // kept for the player to correct
    }
}
