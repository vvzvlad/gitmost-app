import Foundation

// Pure, UI-independent helpers for the "meeting recording" feature: capture system
// audio + microphone into an AAC .m4a and hand it to the open gitmost page via a JS
// bridge. Kept in DocmostCore so the testable bits (file naming, JS contract strings)
// are unit-tested; the Core Audio capture itself lives in the app target.
public enum RecordingSupport {

    /// Deterministic file name for a recording, e.g. "recording-2026-06-23-142530.m4a".
    /// The date is injected so the format is testable without depending on "now".
    public static func fileName(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "recording-\(formatter.string(from: date)).m4a"
    }

    /// MIME type for the produced m4a. Accepted by the gitmost upload + STT whitelist.
    public static let mimeType = "audio/mp4"

    /// Deterministic page title for a recording, e.g. "Recording 2026-06-23 14:25".
    /// Used as the default title when the user must pick a destination for a new page.
    /// The date is injected so the format is testable without depending on "now".
    public static func recordingPageTitle(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Recording \(formatter.string(from: date))"
    }

    /// JS expression (for `callAsyncJavaScript`) that resolves `true` when the in-page
    /// bridge is available. Evaluated in the page content world.
    public static let bridgeAvailabilityJS: String =
        "return typeof window.gitmost?.insertRecording === 'function';"

    /// JS body (for `callAsyncJavaScript`) that invokes the in-page bridge with the
    /// named arguments `base64`, `filename`, `mimeType`. The bridge never throws; it
    /// resolves with `{ ok, attachmentId?, error?, message? }`. We forward that object
    /// straight back to Swift so the caller can decide success vs. fallback.
    public static let insertRecordingJS: String = """
    const result = await window.gitmost.insertRecording({
        base64: base64,
        filename: filename,
        mimeType: mimeType
    });
    return result;
    """

    // MARK: - Destination picker bridge (create a new page from a recording)

    /// JS expression (for `callAsyncJavaScript`) that resolves `true` when the page
    /// creation bridge is available. Evaluated in the page content world. The global
    /// `window.gitmost` bridge is registered even when no editable page is open.
    public static let createPageBridgeAvailabilityJS: String =
        "return typeof window.gitmost?.createPageWithRecording === 'function';"

    /// JS body (for `callAsyncJavaScript`) that lists the spaces the user can write to.
    /// Resolves with `{ ok, spaces?: [{ id, name }], error? }`.
    public static let listSpacesJS: String =
        "return await window.gitmost.listSpaces();"

    /// JS body (for `callAsyncJavaScript`) that lists the pages under a space (or under a
    /// parent page when `parentPageId` is non-empty). Named args: `spaceId`, `parentPageId`
    /// (an empty string means "space root"). Resolves with
    /// `{ ok, pages?: [{ id, title, hasChildren }], error? }`.
    public static let listPagesJS: String = """
    return await window.gitmost.listPages({
        spaceId: spaceId,
        parentPageId: parentPageId || undefined
    });
    """

    /// JS body (for `callAsyncJavaScript`) that creates a new page from a recording.
    /// Named args: `spaceId`, `parentPageId` (empty string ⇒ top level), `title`, `base64`,
    /// `filename`, `mimeType`. Resolves with `{ ok, pageId?, error?, message? }`.
    public static let createPageWithRecordingJS: String = """
    return await window.gitmost.createPageWithRecording({
        spaceId: spaceId,
        parentPageId: parentPageId || undefined,
        title: title,
        base64: base64,
        filename: filename,
        mimeType: mimeType
    });
    """
}

// MARK: - Destination picker models

/// A space the user can create a recording page in.
public struct RecordingSpace: Equatable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A page node in the destination tree, used to pick an optional parent page.
public struct RecordingPageNode: Equatable {
    public let id: String
    public let title: String
    public let hasChildren: Bool
    public init(id: String, title: String, hasChildren: Bool) {
        self.id = id
        self.title = title
        self.hasChildren = hasChildren
    }
}
