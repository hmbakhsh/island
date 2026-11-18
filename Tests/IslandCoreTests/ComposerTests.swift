import Foundation
import XCTest
@testable import IslandCore

final class ComposerTests: XCTestCase {
    let main = Composer.Bot(id: "main-id", name: "Grok Bot")
    let social = Composer.Bot(id: "social-id", name: "Social Bot")
    let scratch = Composer.Project(root: "/u/.t3/scratch", name: "No project", lastUsed: day(1), scratch: true)
    let island = Composer.Project(root: "/u/island", name: "notch-island", lastUsed: day(5))
    let pulse = Composer.Project(root: "/u/pulse", name: "pulse_new", lastUsed: day(4))
    let hiring = Composer.Project(root: "/u/hiring", name: "36labs-hiring", lastUsed: day(2))

    func composer(bots: [Composer.Bot]? = nil, last: Target? = nil) -> Composer {
        var c = Composer(bots: bots ?? [main], projects: [hiring, scratch, pulse, island], lastTarget: last)
        c.open()
        return c
    }

    func names(_ c: Composer) -> [String] { c.rows.map(\.name) }
    func selectedName(_ c: Composer) -> String? { c.rows.indices.contains(c.selection) ? c.rows[c.selection].name : nil }

    // MARK: Opening

    func testStartsClosed() {
        let c = Composer(bots: [main], projects: [], lastTarget: nil)
        XCTAssertEqual(c.mode, .closed)
    }

    func testOpensOnTheLastTarget() {
        let c = composer(last: .t3("/u/pulse"))
        XCTAssertEqual(c.mode, .bar)
        XCTAssertEqual(c.target, .t3("/u/pulse"))
        XCTAssertEqual(c.text, "")
    }

    func testOpensOnTheMainBotWithNoLastTarget() {
        XCTAssertEqual(composer().target, .grok("main-id"))
    }

    func testOpensOnTheMainBotWhenBotsLoadAfterLaunch() {
        var c = Composer(bots: [], projects: [], lastTarget: nil)
        c.bots = [main]
        c.open()
        XCTAssertEqual(c.target, .grok("main-id"))
    }

    func testOpensOnChatGPTWithNoBotsAndNoLastTarget() {
        XCTAssertEqual(composer(bots: []).target, .chatgpt)
    }

    func testReopeningClearsWhatWasTyped() {
        var c = composer()
        c.setText("half a thought")
        XCTAssertEqual(c.press(.escape), [.close])
        c.open()
        XCTAssertEqual(c.text, "")
    }

    // MARK: Sending

    func testEnterSendsPersistsAndCloses() {
        var c = composer(last: .chatgpt)
        c.setText("what's the capital of Peru")
        XCTAssertEqual(c.press(.enter), [.send(.chatgpt, "what's the capital of Peru"), .persistLastTarget(.chatgpt), .close])
        XCTAssertEqual(c.mode, .closed)
    }

    func testEnterOnEmptyTextDoesNothing() {
        var c = composer()
        XCTAssertEqual(c.press(.enter), [])
        XCTAssertEqual(c.mode, .bar)
        c.setText("   \n ")
        XCTAssertEqual(c.press(.enter), [])
        XCTAssertEqual(c.mode, .bar)
    }

    func testSentTextIsTrimmed() {
        var c = composer(last: .chatgpt)
        c.setText("  hi \n")
        XCTAssertEqual(c.press(.enter)?.first, .send(.chatgpt, "hi"))
    }

    func testNextOpenIsAimedAtWhereYouLastSent() {
        var c = composer(bots: [main, social], last: .chatgpt)
        c.press(.backspace)
        c.setText("social")
        c.press(.enter)
        c.setText("ping")
        c.press(.enter)
        c.open()
        XCTAssertEqual(c.target, .grok("social-id"))
    }

    // MARK: Closing

    func testEscWithThePickerClosedClosesTheBar() {
        var c = composer()
        XCTAssertEqual(c.press(.escape), [.close])
        XCTAssertEqual(c.mode, .closed)
    }

    // MARK: Opening the picker

    func testBackspaceOnTextIsLeftToTheField() {
        var c = composer()
        c.setText("a")
        XCTAssertNil(c.press(.backspace))
        XCTAssertEqual(c.mode, .bar)
    }

    func testBackspaceOnEmptyOpensThePickerOnTheCurrentTarget() {
        var c = composer(bots: [main, social], last: .grok("social-id"))
        XCTAssertEqual(c.press(.backspace), [])
        XCTAssertEqual(c.mode, .picker(.top))
        XCTAssertEqual(c.query, "")
        XCTAssertEqual(selectedName(c), "Social Bot")
    }

    func testPickerSelectsTheT3CodeRowWhenAimedAtAProject() {
        var c = composer(last: .t3("/u/pulse"))
        c.press(.backspace)
        XCTAssertEqual(selectedName(c), "T3 Code")
    }

    func testTopLevelIsEnabledBotsThenChatGPTThenT3Code() {
        var c = composer(bots: [main])
        c.press(.backspace)
        XCTAssertEqual(names(c), ["Grok Bot", "ChatGPT", "T3 Code"])
        XCTAssertEqual(c.rows.last?.kind, .t3Code)
    }

    func testOnlyEnabledBotsAreListed() {
        var c = composer(bots: [social])
        c.press(.backspace)
        XCTAssertEqual(names(c), ["Social Bot", "ChatGPT", "T3 Code"])
    }

    func testPickerPlaceholders() {
        var c = composer()
        XCTAssertEqual(c.placeholder, "")
        c.press(.backspace)
        XCTAssertEqual(c.placeholder, "Send to…")
        c.setText("t3")
        c.press(.enter)
        XCTAssertEqual(c.placeholder, "Project…")
    }

    // MARK: Top level

    func testEnterOnATargetAimsTheBarAtIt() {
        var c = composer(last: .t3("/u/pulse"))
        c.press(.backspace)
        c.press(.up)
        c.press(.up)
        XCTAssertEqual(selectedName(c), "Grok Bot")
        XCTAssertEqual(c.press(.enter), [])
        XCTAssertEqual(c.mode, .bar)
        XCTAssertEqual(c.target, .grok("main-id"))
        XCTAssertEqual(c.text, "")
    }

    func testTabOnATargetAimsTheBarAtIt() {
        var c = composer()
        c.press(.backspace)
        c.press(.down)
        c.press(.tab)
        XCTAssertEqual(c.target, .chatgpt)
        XCTAssertEqual(c.mode, .bar)
    }

    func testChoosingATargetDoesNotPersistIt() {
        var c = composer()
        c.press(.backspace)
        c.press(.down)
        XCTAssertEqual(c.press(.enter), [])
    }

    func testArrowsWrap() {
        var c = composer()
        c.press(.backspace)
        XCTAssertEqual(selectedName(c), "Grok Bot")
        c.press(.up)
        XCTAssertEqual(selectedName(c), "T3 Code")
        c.press(.down)
        XCTAssertEqual(selectedName(c), "Grok Bot")
    }

    func testEscAtTopKeepsThePreviousTarget() {
        var c = composer(last: .chatgpt)
        c.press(.backspace)
        c.press(.up)
        XCTAssertEqual(c.press(.escape), [])
        XCTAssertEqual(c.mode, .bar)
        XCTAssertEqual(c.target, .chatgpt)
    }

    func testBackspaceOnEmptyQueryAtTopStaysPut() {
        var c = composer()
        c.press(.backspace)
        XCTAssertEqual(c.press(.backspace), [])
        XCTAssertEqual(c.mode, .picker(.top))
    }

    // MARK: Filtering

    func testTypingFiltersByNameAndResetsSelection() {
        var c = composer(bots: [main, social])
        c.press(.backspace)
        c.press(.down)
        c.press(.down)
        c.setText("bot")
        XCTAssertEqual(names(c), ["Grok Bot", "Social Bot"])
        XCTAssertEqual(c.selection, 0)
        c.setText("CHAT")
        XCTAssertEqual(names(c), ["ChatGPT"])
    }

    func testFilteringDoesNotTouchTheMessage() {
        var c = composer()
        c.press(.backspace)
        c.setText("chat")
        XCTAssertEqual(c.query, "chat")
        XCTAssertEqual(c.text, "")
        c.press(.enter)
        XCTAssertEqual(c.text, "")
        XCTAssertEqual(c.query, "")
    }

    func testBackspaceOnAQueryIsLeftToTheField() {
        var c = composer()
        c.press(.backspace)
        c.setText("c")
        XCTAssertNil(c.press(.backspace))
    }

    func testEnterWithNothingMatchingDoesNothing() {
        var c = composer()
        c.press(.backspace)
        c.setText("zzz")
        XCTAssertEqual(c.rows, [])
        XCTAssertEqual(c.press(.enter), [])
        XCTAssertEqual(c.mode, .picker(.top))
    }

    func testFilteringProjects() {
        var c = composer()
        c.press(.backspace)
        c.setText("t3")
        c.press(.enter)
        c.setText("PUL")
        XCTAssertEqual(names(c), ["pulse_new"])
    }

    // MARK: Projects

    func testEnterOnT3CodeOpensProjectsWithNoProjectFirstThenByRecentUse() {
        var c = composer()
        c.press(.backspace)
        c.press(.up)
        XCTAssertEqual(c.press(.enter), [])
        XCTAssertEqual(c.mode, .picker(.projects))
        XCTAssertEqual(c.query, "")
        XCTAssertEqual(names(c), ["No project", "notch-island", "pulse_new", "36labs-hiring"])
    }

    func testTabOnT3CodeOpensProjects() {
        var c = composer()
        c.press(.backspace)
        c.press(.up)
        c.press(.tab)
        XCTAssertEqual(c.mode, .picker(.projects))
    }

    func testProjectsStartOnTheMostRecentProjectBeforeAnyPick() {
        var c = composer()
        c.press(.backspace)
        c.press(.up)
        c.press(.enter)
        XCTAssertEqual(selectedName(c), "notch-island")
    }

    func testProjectsStartOnTheLastPickedProject() {
        var c = composer()
        c.press(.backspace)
        c.press(.up)
        c.press(.enter)
        c.press(.down)
        c.press(.down)
        XCTAssertEqual(selectedName(c), "36labs-hiring")
        c.press(.enter)
        XCTAssertEqual(c.target, .t3("/u/hiring"))
        XCTAssertEqual(c.mode, .bar)

        // Off to Grok and back: one key.
        c.press(.backspace)
        c.press(.up)
        c.press(.up)
        c.press(.enter)
        XCTAssertEqual(c.target, .grok("main-id"))
        c.press(.backspace)
        c.press(.up)
        c.press(.enter)
        XCTAssertEqual(selectedName(c), "36labs-hiring")
    }

    func testLastPickedProjectComesFromTheLastTarget() {
        var c = composer(last: .t3("/u/pulse"))
        c.press(.backspace)
        c.press(.enter)
        XCTAssertEqual(selectedName(c), "pulse_new")
    }

    func testNoProjectSendsToScratch() {
        var c = composer()
        c.press(.backspace)
        c.press(.up)
        c.press(.enter)
        c.press(.up)
        XCTAssertEqual(selectedName(c), "No project")
        c.press(.tab)
        XCTAssertEqual(c.target, .t3("/u/.t3/scratch"))
        c.setText("scratch question")
        XCTAssertEqual(c.press(.enter)?.first, .send(.t3("/u/.t3/scratch"), "scratch question"))
    }

    func testEscInProjectsGoesBackToTopOnT3Code() {
        var c = composer()
        c.press(.backspace)
        c.press(.up)
        c.press(.enter)
        c.setText("pul")
        XCTAssertEqual(c.press(.escape), [])
        XCTAssertEqual(c.mode, .picker(.top))
        XCTAssertEqual(c.query, "")
        XCTAssertEqual(selectedName(c), "T3 Code")
    }

    func testBackspaceOnEmptyFilterInProjectsGoesBackToTop() {
        var c = composer()
        c.press(.backspace)
        c.press(.up)
        c.press(.enter)
        XCTAssertEqual(c.press(.backspace), [])
        XCTAssertEqual(c.mode, .picker(.top))
        XCTAssertEqual(selectedName(c), "T3 Code")
    }

    func testEscFromProjectsThenTopReturnsToTheBarUnchanged() {
        var c = composer(last: .chatgpt)
        c.press(.backspace)
        c.press(.down)
        c.press(.enter)
        c.press(.escape)
        c.press(.escape)
        XCTAssertEqual(c.mode, .bar)
        XCTAssertEqual(c.target, .chatgpt)
    }

    // MARK: Keys the bar doesn't use

    func testArrowsAndTabInTheBarAreSwallowed() {
        var c = composer()
        XCTAssertEqual(c.press(.up), [])
        XCTAssertEqual(c.press(.down), [])
        XCTAssertEqual(c.press(.tab), [])
        XCTAssertEqual(c.mode, .bar)
    }

    func testClosedIgnoresKeys() {
        var c = Composer(bots: [main], projects: [], lastTarget: nil)
        XCTAssertNil(c.press(.enter))
    }

    // MARK: Targets

    func testTargetsRoundTripThroughTheirStoredForm() {
        for t in [Target.t3("/u/a b"), .grok("abc-1"), .chatgpt] {
            XCTAssertEqual(Target(stored: t.stored), t)
        }
        XCTAssertNil(Target(stored: "nonsense"))
    }
}

private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: Double(n) * 86400) }
