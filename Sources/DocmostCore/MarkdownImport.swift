import Foundation

// Pure, UI-independent helpers for the "drop a Markdown file on the window to import
// it as a Docmost page" feature. Kept in DocmostCore so the logic is unit-tested.
public enum MarkdownImport {

    // File extensions Docmost's Markdown importer accepts (matches the web UI's
    // Markdown FileButton `accept=".md"`). Compared case-insensitively.
    public static let markdownExtensions: Set<String> = ["md", "markdown"]

    // Upper bound on a single imported file, mirroring Docmost's 30 MB per-file limit.
    public static let maxFileSize: Int = 30 * 1024 * 1024

    /// True when `url` is a local Markdown file by extension (case-insensitive).
    public static func isMarkdownFile(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// Keeps only the importable Markdown files from a dropped set, preserving order.
    public static func importableMarkdownFiles(from urls: [URL]) -> [URL] {
        urls.filter(isMarkdownFile)
    }

    /// Extracts the Docmost space slug from a web-app path. Space pages live under
    /// "/s/{slug}" (optionally followed by "/p/{pageSlug}"). Returns nil when the path
    /// is not inside a space (home, share pages, settings, etc.).
    public static func spaceSlug(fromPath path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.first == "s", parts.count > 1 else { return nil }
        let slug = parts[1]
        return slug.isEmpty ? nil : slug
    }

    // Async function body for `WKWebView.callAsyncJavaScript`. Receives two arguments:
    // `slug` (String) and `files` (Array of { name, b64 }). It resolves the space id
    // from the slug, then POSTs each file to Docmost's import endpoint using the page's
    // own session cookie (credentials: "include"), exactly like the web app's
    // importPage() does. Returns { ok, imported, errors }.
    public static let importMarkdownJS: String = """
    const infoResp = await fetch('/api/spaces/info', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        credentials: 'include',
        body: JSON.stringify({ spaceId: slug })
    });
    if (!infoResp.ok) { return { ok: false, imported: 0, errors: ['space-info ' + infoResp.status] }; }
    const info = await infoResp.json();
    const spaceId = (info && (info.id || (info.data && info.data.id)));
    if (!spaceId) { return { ok: false, imported: 0, errors: ['space-not-found'] }; }

    function b64ToBytes(b64) {
        const bin = atob(b64);
        const bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) { bytes[i] = bin.charCodeAt(i); }
        return bytes;
    }

    let imported = 0;
    const errors = [];
    for (const f of files) {
        try {
            const blob = new Blob([b64ToBytes(f.b64)], { type: 'text/markdown' });
            const file = new File([blob], f.name, { type: 'text/markdown' });
            const fd = new FormData();
            fd.append('spaceId', spaceId);
            fd.append('file', file);
            const resp = await fetch('/api/pages/import', { method: 'POST', credentials: 'include', body: fd });
            if (!resp.ok) { errors.push(f.name + ': ' + resp.status); continue; }
            imported++;
        } catch (e) {
            errors.push(f.name + ': ' + ((e && e.message) ? e.message : 'error'));
        }
    }
    return { ok: errors.length === 0, imported: imported, errors: errors };
    """
}
