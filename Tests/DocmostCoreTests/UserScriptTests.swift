import XCTest
@testable import DocmostCore

final class UserScriptTests: XCTestCase {

    // MARK: - UserScripts

    func testStyleInjectionJSEscapesSpecialChars() {
        // CSS containing a double quote, a backslash and a backtick.
        let css = "a\"b\\c`d"
        let js = UserScripts.styleInjectionJS(forCSS: css)

        // Builds a <style> element and appends it.
        XCTAssertTrue(js.contains("createElement('style')"))
        XCTAssertTrue(js.contains("appendChild"))

        // The double quote is JSON-escaped.
        XCTAssertTrue(js.contains("\\\""))
        // The backslash is JSON-escaped (two backslashes in the literal).
        XCTAssertTrue(js.contains("\\\\"))
    }

    func testJSStringLiteralEscaping() {
        // a"b -> "a\"b" as a JSON string literal (with surrounding quotes).
        XCTAssertEqual(UserScripts.jsStringLiteral("a\"b"), "\"a\\\"b\"")
    }

    // MARK: - Embedded global JS

    func testEmbeddedJSHidesResolvedUI() {
        // The built-in script targets the paid-only resolved-comments UI.
        XCTAssertTrue(UserScripts.js.contains("resolve comment"))
        XCTAssertTrue(UserScripts.js.contains("resolved"))
        // It uses a MutationObserver because the menu is rendered on demand.
        XCTAssertTrue(UserScripts.js.contains("MutationObserver"))
    }
}
