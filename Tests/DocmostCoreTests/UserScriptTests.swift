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

    func testEmbeddedJSHidesResolveCommentUI() {
        // The built-in script hides the paid-only "Resolve comment" / "Re-open comment" menu item.
        XCTAssertTrue(UserScripts.js.contains("resolvecomment"))
        XCTAssertTrue(UserScripts.js.contains("reopencomment"))
        // It uses a MutationObserver because the menu is rendered on demand.
        XCTAssertTrue(UserScripts.js.contains("MutationObserver"))
    }

    func testEmbeddedJSHidesPaidVerificationAndTemplatesUI() {
        let js = UserScripts.js
        // Hides the paid-only "Add/Edit verification" menu item (tied to the code, not a comment).
        XCTAssertTrue(js.contains("indexOf('verification')"))
        // Hides the paid-only "Templates" menu item (exact text match).
        XCTAssertTrue(js.contains("'templates'"))
        // The top-level nav "Templates" link is matched within the navbar scope.
        XCTAssertTrue(js.contains("[class*=\"_navbar_\"] [class*=\"_link_\"]"))
    }

    func testEmbeddedCSSHidesVerificationButton() {
        // The page-header verification ActionIcon is matched by its aria-label.
        XCTAssertTrue(UserScripts.css.contains("aria-label*=\"verification\""))
    }

    // MARK: - Embedded global CSS

    func testEmbeddedCSSAppliesUICustomizations() {
        let css = UserScripts.css
        // Hides the space sidebar action menu (Overview / Search / Space settings / New page).
        XCTAssertTrue(css.contains("_menuItems_"))
        // The comments panel must stay visible: the old "-tab-resolved" hide rule is gone.
        XCTAssertFalse(css.contains("-tab-resolved"))
        // Shrinks the page tree indentation via per-level aria-level overrides.
        XCTAssertTrue(css.contains("[role=\"treeitem\"][aria-level=\"2\"]"))
    }
}
