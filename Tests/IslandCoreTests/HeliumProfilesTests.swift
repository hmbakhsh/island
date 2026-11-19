import Foundation
import XCTest
@testable import IslandCore

final class HeliumProfilesTests: XCTestCase {
    let localState = Data(#"""
        {"profile": {"info_cache": {
          "Default": {"name": "Personal"},
          "Profile 2": {"name": "Prism"},
          "Profile 3": {"name": "36 Labs"}
        }, "last_used": "Profile 3"}}
        """#.utf8)

    func testListsProfilesByDisplayName() {
        let profiles = HeliumProfiles.list(localState: localState)
        XCTAssertEqual(profiles.map(\.name), ["36 Labs", "Personal", "Prism"])
        XCTAssertEqual(profiles.first?.directory, "Profile 3")
    }

    func testDefaultIs36Labs() {
        let profiles = HeliumProfiles.list(localState: localState)
        XCTAssertEqual(HeliumProfiles.defaultProfile(in: profiles)?.directory, "Profile 3")
        XCTAssertNil(HeliumProfiles.defaultProfile(in: profiles.filter { $0.name != "36 Labs" }))
    }

    func testBadLocalStateListsNothing() {
        XCTAssertEqual(HeliumProfiles.list(localState: Data("nope".utf8)), [])
    }

    func testReadsURLsOutOfBinarySessionFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("helium-\(UUID().uuidString)")
        let sessions = dir.appendingPathComponent("Profile 3/Sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        var bytes: [UInt8] = [0, 1, 2, 0x1f]
        bytes += Array("https://chatgpt.com/c/abc".utf8) + [0, 0x10, 0xff] + Array("Title".utf8) + [0]
        bytes += Array("https://x.com/a".utf8) + [7]
        try Data(bytes).write(to: sessions.appendingPathComponent("Session_123"))
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(HeliumProfiles.sessionURLs(profile: "Profile 3", in: dir), ["https://chatgpt.com/c/abc", "https://x.com/a"])
        XCTAssertEqual(HeliumProfiles.sessionURLs(profile: "Default", in: dir), [])
    }

    func testWindowOwnerIsTheProfileHoldingItsTabs() {
        let sessions: [String: Set<String>] = [
            "Default": ["https://news.ycombinator.com/"],
            "Profile 3": ["https://linear.app/x", "https://github.com/a", "https://chatgpt.com/"],
        ]
        let tabs = ["https://linear.app/x", "https://github.com/a", "https://brand-new.example/", "chrome://newtab/"]
        XCTAssertEqual(HeliumProfiles.owner(ofTabs: tabs, sessions: sessions), "Profile 3")
    }

    func testNoGuessWhenTabsMatchNobody() {
        let sessions: [String: Set<String>] = ["Profile 3": ["https://a.example/"]]
        XCTAssertNil(HeliumProfiles.owner(ofTabs: ["https://b.example/", "https://c.example/"], sessions: sessions))
        XCTAssertNil(HeliumProfiles.owner(ofTabs: ["chrome://newtab/"], sessions: sessions))
    }

    func testNoGuessWhenTwoProfilesShareTheTabs() {
        let shared: Set<String> = ["https://google.com/", "https://github.com/"]
        let sessions = ["Default": shared, "Profile 3": shared]
        XCTAssertNil(HeliumProfiles.owner(ofTabs: Array(shared), sessions: sessions))
    }
}
