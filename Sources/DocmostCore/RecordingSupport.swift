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
}
