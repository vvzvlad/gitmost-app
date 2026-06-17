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

    // MARK: - No custom injection

    func testNoCustomScriptsAreInjected() {
        // The app ships without custom CSS/JS injection — the web UI is shown as served.
        XCTAssertTrue(UserScripts.css.isEmpty)
        XCTAssertTrue(UserScripts.js.isEmpty)
    }
}
