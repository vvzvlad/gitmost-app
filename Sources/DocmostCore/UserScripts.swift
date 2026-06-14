import Foundation

// Built-in scripts injected into every Docmost server tab, plus CSS-injection helpers.
public enum UserScripts {

    // Global CSS injected into every Docmost server tab.
    // Notes: Docmost is built with Vite CSS modules, whose production class
    // names keep the source name as a prefix (e.g. ".menuItems" becomes
    // "._menuItems_1k1tz_32"). Substring matching on that prefix is stable
    // across rebuilds; the trailing hash is not. ":has()" is available because
    // the app targets macOS 14+ (WebKit with :has support).
    public static let css: String = """
    /* 1. Remove the space sidebar action block (Overview / Search /
          Space settings / New page). The space switcher and the page tree are
          left untouched. ".menuItems" lives inside a ".section"; hiding the
          whole section drops its divider and spacing too. The second selector
          is a navbar-scoped fallback that still hides the menu if the wrapping
          section ever changes, without matching a stray ".menuItems" elsewhere. */
    [class*="_section_"]:has([class*="_menuItems_"]),
    [class*="_navbar_"] [class*="_menuItems_"] {
        display: none !important;
    }

    /* 2. Remove the Comments panel. The right Aside is shared by Comments,
          Table of contents and Details, so it is hidden only while it shows the
          comment tabs. Mantine builds tab ids as "{id}-tab-{value}", so the
          "Resolved" tab id ends with "-tab-resolved" — unique to the comments
          panel and present even when that tab is visually hidden elsewhere. */
    [class*="_aside_"]:has([role="tab"][id*="-tab-resolved"]) {
        display: none !important;
    }

    /* 3. Shrink the page tree indentation. react-arborist applies an inline
          "padding-left: level * 24px" to each row's node element; the row is
          "[role=treeitem]" with "aria-level = level + 1". Override per level to
          an 8px step (author !important beats the inline style). Levels deeper
          than listed keep the default indentation. */
    [role="treeitem"][aria-level="2"] [class*="_node_"] { padding-left: 8px !important; }
    [role="treeitem"][aria-level="3"] [class*="_node_"] { padding-left: 16px !important; }
    [role="treeitem"][aria-level="4"] [class*="_node_"] { padding-left: 24px !important; }
    [role="treeitem"][aria-level="5"] [class*="_node_"] { padding-left: 32px !important; }
    [role="treeitem"][aria-level="6"] [class*="_node_"] { padding-left: 40px !important; }
    [role="treeitem"][aria-level="7"] [class*="_node_"] { padding-left: 48px !important; }
    [role="treeitem"][aria-level="8"] [class*="_node_"] { padding-left: 56px !important; }
    [role="treeitem"][aria-level="9"] [class*="_node_"] { padding-left: 64px !important; }
    [role="treeitem"][aria-level="10"] [class*="_node_"] { padding-left: 72px !important; }
    [role="treeitem"][aria-level="11"] [class*="_node_"] { padding-left: 80px !important; }
    [role="treeitem"][aria-level="12"] [class*="_node_"] { padding-left: 88px !important; }
    [role="treeitem"][aria-level="13"] [class*="_node_"] { padding-left: 96px !important; }
    [role="treeitem"][aria-level="14"] [class*="_node_"] { padding-left: 104px !important; }
    [role="treeitem"][aria-level="15"] [class*="_node_"] { padding-left: 112px !important; }
    [role="treeitem"][aria-level="16"] [class*="_node_"] { padding-left: 120px !important; }
    [role="treeitem"][aria-level="17"] [class*="_node_"] { padding-left: 128px !important; }
    [role="treeitem"][aria-level="18"] [class*="_node_"] { padding-left: 136px !important; }
    [role="treeitem"][aria-level="19"] [class*="_node_"] { padding-left: 144px !important; }
    [role="treeitem"][aria-level="20"] [class*="_node_"] { padding-left: 152px !important; }
    """

    // Global JS injected into every Docmost server tab.
    // Currently: hides the paid-only "Resolved" comments UI, which is unavailable.
    public static let js: String = """
    (function () {
        // Hide the unavailable paid-only "Resolved" comments UI inside Docmost.
        function hide(el) { if (el && el.style) { el.style.display = 'none'; } }

        // Letters-only text, so a count badge ("0Resolved") still matches the tab but
        // unrelated text ("Unresolved", "5 resolved threads") does not.
        function letters(el) { return (el.textContent || '').toLowerCase().replace(/[^a-z]/g, ''); }

        function sweep() {
            try {
                // The "Resolved" tab in the comments panel (exact match, ignoring the count).
                document.querySelectorAll('[role="tab"], .mantine-Tabs-tab').forEach(function (el) {
                    if (letters(el) === 'resolved') hide(el);
                });
                // The "Resolve comment" item in a comment's context menu (disabled, paid-only).
                document.querySelectorAll('[role="menuitem"], .mantine-Menu-item').forEach(function (el) {
                    if ((el.textContent || '').trim().toLowerCase().indexOf('resolve comment') !== -1) hide(el);
                });
            } catch (e) { /* ignore */ }
        }

        // Coalesce bursts of DOM mutations into one sweep per frame.
        var raf = window.requestAnimationFrame
            ? window.requestAnimationFrame.bind(window)
            : function (cb) { return window.setTimeout(cb, 16); };
        var scheduled = false;
        function schedule() {
            if (scheduled) return;
            scheduled = true;
            raf(function () { scheduled = false; sweep(); });
        }

        function start() {
            sweep();
            var target = document.body || document.documentElement;
            if (!target) return;
            // Docmost is an SPA and the comment menu is rendered on demand, so observe
            // the DOM and re-sweep (throttled) on changes.
            var obs = new MutationObserver(schedule);
            obs.observe(target, { childList: true, subtree: true });
        }

        if (document.body) start();
        else document.addEventListener('DOMContentLoaded', start);
    })();
    """

    // JS that appends the given CSS as a <style> element. The CSS is encoded as a
    // JSON string literal so quotes/backticks/backslashes cannot break the script.
    public static func styleInjectionJS(forCSS css: String) -> String {
        let literal = jsStringLiteral(css)
        return "(function(){var s=document.createElement('style');"
            + "s.setAttribute('data-docmost-custom','');"
            + "s.textContent=\(literal);"
            + "(document.head||document.documentElement).appendChild(s);})();"
    }

    // Encodes a Swift string as a JS/JSON string literal (including the surrounding quotes).
    static func jsStringLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        // json looks like ["...escaped..."]; strip the surrounding array brackets.
        return String(json.dropFirst().dropLast())
    }
}
