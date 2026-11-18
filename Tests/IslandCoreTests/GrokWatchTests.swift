import Foundation
import XCTest
@testable import IslandCore

/// Saved roster files in, banners out.
final class GrokWatchTests: XCTestCase {
    /// Grok Bot names its files with the lowercase base32 of a key; this one
    /// is "sand.client.slice.account.github%7C42.roster.last-roster".
    let rosterName = "onqw4zbomnwgszlooqxhg3djmnss4yldmnxxk3tufztws5diovrckn2dgqzc44tpon2gk4ronrqxg5bnojxxg5dfoi.blob"
    /// "…selection.last-agent": a neighbour that must be ignored.
    let otherName = "onqw4zbomnwgszlooqxhg3djmnss4yldmnxxk3tufztws5diovrckn2dgqzc443fnrswg5djn5xc43dbon2c2ylhmvxhi.blob"
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("grok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1,"value":"3536e392"}"#.utf8).write(to: dir.appendingPathComponent(otherName))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Puts a saved roster in place, as Grok Bot does.
    func feed(_ fixture: String) throws {
        let url = Bundle.module.url(forResource: fixture, withExtension: "json", subdirectory: "Fixtures")!
        let target = dir.appendingPathComponent(rosterName)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: url, to: target)
    }

    func summary(_ events: [GrokEvent]) -> [String] {
        events.map { "\($0.kind == .needsYou ? "needs you" : "replied"): \($0.bot.name): \($0.bot.lastText ?? "")" }
    }

    func testFirstReadIsQuiet() throws {
        try feed("1-launch")
        let watch = GrokWatch(directory: dir)
        XCTAssertEqual(watch.poll(), [])
        XCTAssertEqual(watch.bots.map(\.name), ["Grok Bot", "Social Bot", "36 Hiring"])
    }

    func testFirstReadIsQuietEvenWithUnreadsAndQuestionsWaiting() throws {
        try feed("4-hiring-needs-you")
        let watch = GrokWatch(directory: dir)
        XCTAssertEqual(watch.poll(), [])
        XCTAssertEqual(watch.poll(), [])
    }

    func testNoRosterYetIsQuietAndThenSeeds() throws {
        let watch = GrokWatch(directory: dir)
        XCTAssertEqual(watch.poll(), [])
        try feed("2-social-replies")
        XCTAssertEqual(watch.poll(), [], "the first roster seen seeds, even if it appears late")
    }

    func testBannerOnANewReply() throws {
        try feed("1-launch")
        let watch = GrokWatch(directory: dir)
        watch.poll()
        try feed("2-social-replies")
        XCTAssertEqual(summary(watch.poll()), ["replied: Social Bot: Found a jazz night on Friday."])
        XCTAssertEqual(watch.poll(), [], "one banner per reply")
    }

    func testBannersCoverBotsOutsideThePicker() throws {
        // The watcher has no picker list at all: every bot in the roster counts.
        try feed("1-launch")
        let watch = GrokWatch(directory: dir)
        watch.poll()
        try feed("2-social-replies")
        try feed("3-own-message")
        try feed("4-hiring-needs-you")
        try feed("5-main-replies")
        XCTAssertEqual(summary(watch.poll()), [
            "replied: Social Bot: Found a jazz night on Friday.",
            "needs you: 36 Hiring: Should I send the rejections?",
            "replied: Grok Bot: Done. Booked the table for 8pm.",
        ])
    }

    func testNoBannerForYourOwnMessage() throws {
        try feed("2-social-replies")
        let watch = GrokWatch(directory: dir)
        watch.poll()
        try feed("3-own-message")
        XCTAssertEqual(watch.poll(), [])
    }

    func testNeedsYouBanner() throws {
        try feed("3-own-message")
        let watch = GrokWatch(directory: dir)
        watch.poll()
        try feed("4-hiring-needs-you")
        let events = watch.poll()
        XCTAssertEqual(summary(events), ["needs you: 36 Hiring: Should I send the rejections?"])
        XCTAssertEqual(events.first?.bot.id, "hiring-id")
        XCTAssertEqual(events.first?.bot.avatarShape, "flower")
        XCTAssertEqual(events.first?.bot.avatarColor, "magenta")
    }

    func testReplyAfterOwnMessage() throws {
        try feed("1-launch")
        let watch = GrokWatch(directory: dir)
        watch.poll()
        try feed("3-own-message")
        XCTAssertEqual(watch.poll().count, 1, "Social Bot's reply is still new to this watcher")
        try feed("5-main-replies")
        XCTAssertEqual(summary(watch.poll()), [
            "needs you: 36 Hiring: Should I send the rejections?",
            "replied: Grok Bot: Done. Booked the table for 8pm.",
        ])
    }

    func testBannersOff() throws {
        try feed("1-launch")
        let watch = GrokWatch(directory: dir)
        watch.announces = false
        watch.poll()
        try feed("2-social-replies")
        XCTAssertEqual(watch.poll(), [])
        // Turned back on: only what happens from now on.
        watch.announces = true
        XCTAssertEqual(watch.poll(), [])
        try feed("4-hiring-needs-you")
        XCTAssertEqual(summary(watch.poll()), ["needs you: 36 Hiring: Should I send the rejections?"])
    }

    func testABrokenRosterIsIgnored() throws {
        try feed("1-launch")
        let watch = GrokWatch(directory: dir)
        watch.poll()
        try Data("{not json".utf8).write(to: dir.appendingPathComponent(rosterName))
        XCTAssertEqual(watch.poll(), [])
        XCTAssertEqual(watch.bots.count, 3, "keeps the last good roster")
        try feed("2-social-replies")
        XCTAssertEqual(watch.poll().count, 1)
    }

    func testMainBotIsTheOldestNamedGrokBot() throws {
        try feed("1-launch")
        let watch = GrokWatch(directory: dir)
        watch.poll()
        XCTAssertEqual(GrokWatch.mainBot(in: watch.bots)?.id, "main-id")
    }
}
