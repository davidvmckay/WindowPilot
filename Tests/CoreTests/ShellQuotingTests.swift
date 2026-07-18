import XCTest
import WindowPilotCore

final class ShellQuotingTests: XCTestCase {

    // MARK: - appleScriptStringLiteral escaping

    func testEscapesDoubleQuote() {
        let s = ShellQuoting.appleScriptStringLiteral("/tmp/say \"hi\"")
        XCTAssertEqual(s, "/tmp/say \\\"hi\\\"")
    }

    func testEscapesBackslash() {
        let s = ShellQuoting.appleScriptStringLiteral("C:\\Users\\evil")
        XCTAssertEqual(s, "C:\\\\Users\\\\evil")
    }

    func testEscapesCommandSubstitutionCharsLiterally() {
        // $( and ) are not special to AppleScript string literals — the
        // safety net against them is `quoted form of` on the shell side,
        // not escaping here. They must survive untouched.
        let s = ShellQuoting.appleScriptStringLiteral("/tmp/$(rm -rf ~)")
        XCTAssertEqual(s, "/tmp/$(rm -rf ~)")
    }

    func testEscapesBacktick() {
        let s = ShellQuoting.appleScriptStringLiteral("/tmp/`rm -rf ~`")
        XCTAssertEqual(s, "/tmp/`rm -rf ~`")
    }

    func testPreservesUnicodePath() {
        let s = ShellQuoting.appleScriptStringLiteral("/tmp/日本語/résumé")
        XCTAssertEqual(s, "/tmp/日本語/résumé")
    }

    func testEscapesBackslashBeforeQuoteInCorrectOrder() {
        // A literal backslash-quote sequence must escape the backslash
        // first, then the quote — not the reverse (which would corrupt it).
        let s = ShellQuoting.appleScriptStringLiteral("\\\"")
        XCTAssertEqual(s, "\\\\\\\"")
    }

    // MARK: - control character rejection

    func testDetectsControlCharacters() {
        XCTAssertTrue(ShellQuoting.containsControlCharacters("/tmp/evil\npath"))
        XCTAssertTrue(ShellQuoting.containsControlCharacters("/tmp/evil\u{01}path"))
        XCTAssertTrue(ShellQuoting.containsControlCharacters("/tmp/evil\u{00}path"))
        XCTAssertTrue(ShellQuoting.containsControlCharacters("/tmp/evil\u{1F}path"))
    }

    func testCleanPathHasNoControlCharacters() {
        XCTAssertFalse(ShellQuoting.containsControlCharacters("/Applications/WindowPilot.app"))
        XCTAssertFalse(ShellQuoting.containsControlCharacters("/tmp/日本語/résumé"))
    }
}
