import Foundation

// Built-in scripts injected into every Docmost server tab, plus CSS-injection helpers.
//
// Adding/altering UI filters or custom components? Read the playbook first:
// .claude/skills/web-ui-injection/SKILL.md (how to find rebuild-stable
// selectors against the DEPLOYED Docmost build, not GitHub main).
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

    /* 2. Shrink the page tree indentation. The current DocTree applies an inline
          "padding-left: level * 16px" to each row's ".rowWrapper" wrapper; the
          row's "[role=treeitem]" (with "aria-level = level + 1") sits inside it.
          Target the wrapper via :has() and override per level to an 8px step
          (author !important beats the inline style). Levels deeper than listed
          keep the default indentation. */
    [class*="_rowWrapper_"]:has([role="treeitem"][aria-level="2"]) { padding-left: 8px !important; }
    [class*="_rowWrapper_"]:has([role="treeitem"][aria-level="3"]) { padding-left: 16px !important; }
    [class*="_rowWrapper_"]:has([role="treeitem"][aria-level="4"]) { padding-left: 24px !important; }
    [class*="_rowWrapper_"]:has([role="treeitem"][aria-level="5"]) { padding-left: 32px !important; }
    [class*="_rowWrapper_"]:has([role="treeitem"][aria-level="6"]) { padding-left: 40px !important; }
    [class*="_rowWrapper_"]:has([role="treeitem"][aria-level="7"]) { padding-left: 48px !important; }
    [class*="_rowWrapper_"]:has([role="treeitem"][aria-level="8"]) { padding-left: 56px !important; }
    [class*="_rowWrapper_"]:has([role="treeitem"][aria-level="9"]) { padding-left: 64px !important; }
    [class*="_rowWrapper_"]:has([role="treeitem"][aria-level="10"]) { padding-left: 72px !important; }
    [class*="_rowWrapper_"]:has([role="treeitem"][aria-level="11"]) { padding-left: 80px !important; }
    [class*="_rowWrapper_"]:has([role="treeitem"][aria-level="12"]) { padding-left: 88px !important; }
    [class*="_rowWrapper_"]:has([role="treeitem"][aria-level="13"]) { padding-left: 96px !important; }
    [class*="_rowWrapper_"]:has([role="treeitem"][aria-level="14"]) { padding-left: 104px !important; }
    [class*="_rowWrapper_"]:has([role="treeitem"][aria-level="15"]) { padding-left: 112px !important; }
    [class*="_rowWrapper_"]:has([role="treeitem"][aria-level="16"]) { padding-left: 120px !important; }
    [class*="_rowWrapper_"]:has([role="treeitem"][aria-level="17"]) { padding-left: 128px !important; }
    [class*="_rowWrapper_"]:has([role="treeitem"][aria-level="18"]) { padding-left: 136px !important; }
    [class*="_rowWrapper_"]:has([role="treeitem"][aria-level="19"]) { padding-left: 144px !important; }
    [class*="_rowWrapper_"]:has([role="treeitem"][aria-level="20"]) { padding-left: 152px !important; }
    """

    // Global JS injected into every Docmost server tab.
    // Currently: hides the unavailable paid-only "Resolve comment" action in the
    // per-comment menu. Comments themselves stay visible.
    public static let js: String = """
    (function () {
        // Hide a matched element (the unavailable paid-only resolve action).
        function hide(el) { if (el && el.style) { el.style.display = 'none'; } }

        // Letters-only text, so a label matches regardless of icons/whitespace.
        function letters(el) { return (el.textContent || '').toLowerCase().replace(/[^a-z]/g, ''); }

        function sweep() {
            try {
                // The "Resolve comment" / "Re-open comment" item in a comment's
                // context menu (Mantine Menu.Item; a paid-only, unavailable action).
                // Comments stay visible — only this menu entry is removed.
                document.querySelectorAll('[role="menuitem"], .mantine-Menu-item').forEach(function (el) {
                    var t = letters(el);
                    if (t === 'resolvecomment' || t === 'reopencomment') hide(el);
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
