import Foundation

// Built-in scripts injected into every Docmost server tab, plus CSS-injection helpers.
public enum UserScripts {

    // Global CSS injected into every Docmost server tab. Empty for now.
    public static let css: String = ""

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
