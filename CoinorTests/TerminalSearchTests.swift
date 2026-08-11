import AppKit
import XCTest
@testable import Coinor

final class TerminalSearchTests: XCTestCase {
    func testBindingActionStringsMatchTheCoreVocabulary() {
        XCTAssertEqual(TerminalSearchAction.start.bindingAction, "start_search")
        XCTAssertEqual(
            TerminalSearchAction.selection.bindingAction,
            "search_selection"
        )
        XCTAssertEqual(
            TerminalSearchAction.needle("foo").bindingAction,
            "search:foo"
        )
        XCTAssertEqual(
            TerminalSearchAction.next.bindingAction,
            "navigate_search:next"
        )
        XCTAssertEqual(
            TerminalSearchAction.previous.bindingAction,
            "navigate_search:previous"
        )
        XCTAssertEqual(TerminalSearchAction.end.bindingAction, "end_search")
    }

    func testNeedlesKeepEveryCharacterAfterTheFirstColon() {
        XCTAssertEqual(
            TerminalSearchAction.needle("a:b").bindingAction,
            "search:a:b"
        )
        XCTAssertEqual(
            TerminalSearchAction.needle("").bindingAction,
            "search:"
        )
        XCTAssertEqual(
            TerminalSearchAction.needle("one\ntwo").bindingAction,
            "search:one\ntwo"
        )
    }

    func testDebounceDelaysOnlyShortNeedles() {
        XCTAssertEqual(
            TerminalSearchDebouncePolicy.delay(forNeedleLength: 0),
            .zero
        )
        XCTAssertEqual(
            TerminalSearchDebouncePolicy.delay(forNeedleLength: 1),
            .milliseconds(300)
        )
        XCTAssertEqual(
            TerminalSearchDebouncePolicy.delay(forNeedleLength: 2),
            .milliseconds(300)
        )
        XCTAssertEqual(
            TerminalSearchDebouncePolicy.delay(forNeedleLength: 3),
            .zero
        )
        XCTAssertEqual(
            TerminalSearchDebouncePolicy.delay(forNeedleLength: 42),
            .zero
        )
    }

    func testStatusLabelCountsMatchesFromOne() {
        XCTAssertEqual(
            TerminalSearchStatus.label(
                total: 17,
                selected: 2,
                needleIsEmpty: false
            ),
            "3/17"
        )
        XCTAssertEqual(
            TerminalSearchStatus.label(
                total: 1,
                selected: 0,
                needleIsEmpty: false
            ),
            "1/1"
        )
    }

    func testStatusLabelTreatsMinusOneAsNothingReported() {
        XCTAssertEqual(
            TerminalSearchStatus.label(
                total: -1,
                selected: -1,
                needleIsEmpty: false
            ),
            "0/0"
        )
        XCTAssertEqual(
            TerminalSearchStatus.label(
                total: 0,
                selected: -1,
                needleIsEmpty: false
            ),
            "0/0"
        )
        XCTAssertEqual(
            TerminalSearchStatus.label(
                total: 17,
                selected: -1,
                needleIsEmpty: false
            ),
            "17"
        )
        XCTAssertEqual(
            TerminalSearchStatus.label(
                total: 17,
                selected: nil,
                needleIsEmpty: false
            ),
            "17"
        )
        XCTAssertEqual(
            TerminalSearchStatus.label(
                total: nil,
                selected: nil,
                needleIsEmpty: false
            ),
            "0/0"
        )
    }

    func testStatusLabelStaysSilentWithoutANeedle() {
        XCTAssertNil(
            TerminalSearchStatus.label(
                total: nil,
                selected: nil,
                needleIsEmpty: true
            )
        )
        XCTAssertNil(
            TerminalSearchStatus.label(
                total: 17,
                selected: 2,
                needleIsEmpty: true
            )
        )
    }

    func testMatchAvailabilityIgnoresTheMinusOneSentinel() {
        XCTAssertFalse(TerminalSearchStatus.hasMatches(total: nil))
        XCTAssertFalse(TerminalSearchStatus.hasMatches(total: -1))
        XCTAssertFalse(TerminalSearchStatus.hasMatches(total: 0))
        XCTAssertTrue(TerminalSearchStatus.hasMatches(total: 1))
    }

    func testCommandShortcutsMapToFindActions() {
        XCTAssertEqual(
            TerminalSearchShortcut.command(
                forCharacters: "f",
                modifiers: [.command]
            ),
            .find
        )
        XCTAssertEqual(
            TerminalSearchShortcut.command(
                forCharacters: "g",
                modifiers: [.command]
            ),
            .findNext
        )
        XCTAssertEqual(
            TerminalSearchShortcut.command(
                forCharacters: "G",
                modifiers: [.command, .shift]
            ),
            .findPrevious
        )
    }

    func testShortcutMatcherRejectsEveryOtherCombination() {
        XCTAssertNil(
            TerminalSearchShortcut.command(forCharacters: "f", modifiers: [])
        )
        XCTAssertNil(
            TerminalSearchShortcut.command(
                forCharacters: "f",
                modifiers: [.control]
            )
        )
        XCTAssertNil(
            TerminalSearchShortcut.command(
                forCharacters: "f",
                modifiers: [.command, .option]
            )
        )
        XCTAssertNil(
            TerminalSearchShortcut.command(
                forCharacters: "f",
                modifiers: [.command, .shift]
            )
        )
        XCTAssertNil(
            TerminalSearchShortcut.command(
                forCharacters: "g",
                modifiers: [.command, .control]
            )
        )
        XCTAssertNil(
            TerminalSearchShortcut.command(
                forCharacters: nil,
                modifiers: [.command]
            )
        )
    }
}
