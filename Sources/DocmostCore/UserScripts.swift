import Foundation

// CSS/JS injection points for the web UI, plus CSS-injection helpers.
//
// The app injects no custom CSS or JS: it shows the web UI exactly as the
// server serves it. The empty `css`/`js` constants below remain only as an
// extension point — WebTab.installUserScripts skips injection when they are
// empty, so filling them in here is all that future customization would need.
public enum UserScripts {

    // Custom CSS to inject into every server tab. Empty: nothing is injected.
    public static let css: String = ""

    // Custom JS to inject into every server tab. Empty: nothing is injected.
    public static let js: String = ""

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
