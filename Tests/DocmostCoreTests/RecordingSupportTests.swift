import XCTest
@testable import DocmostCore

final class RecordingSupportTests: XCTestCase {

    // Builds a fixed-instant date in a fixed time zone so the formatted name is
    // deterministic regardless of the machine's locale/zone.
    private func fixedDate() -> (date: Date, calendar: Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 23
        components.hour = 14
        components.minute = 25
        components.second = 30
        let date = calendar.date(from: components)!
        return (date, calendar)
    }

    func testFileNameHasDeterministicFormat() {
        let (date, calendar) = fixedDate()
        XCTAssertEqual(RecordingSupport.fileName(for: date, calendar: calendar),
                       "recording-2026-06-23-142530.m4a")
    }

    func testFileNamePadsSingleDigitComponents() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 5
        components.hour = 9
        components.minute = 3
        components.second = 7
        let date = calendar.date(from: components)!
        XCTAssertEqual(RecordingSupport.fileName(for: date, calendar: calendar),
                       "recording-2026-01-05-090307.m4a")
    }

    func testMimeTypeIsM4A() {
        XCTAssertEqual(RecordingSupport.mimeType, "audio/mp4")
    }

    func testBridgeAvailabilityJSProbesTheBridge() {
        let js = RecordingSupport.bridgeAvailabilityJS
        XCTAssertTrue(js.contains("window.gitmost?.insertRecording"))
        XCTAssertTrue(js.contains("typeof"))
        XCTAssertTrue(js.contains("function"))
    }

    func testInsertRecordingJSCallsTheBridgeWithNamedArgs() {
        let js = RecordingSupport.insertRecordingJS
        XCTAssertTrue(js.contains("window.gitmost.insertRecording"))
        XCTAssertTrue(js.contains("base64"))
        XCTAssertTrue(js.contains("filename"))
        XCTAssertTrue(js.contains("mimeType"))
    }
}
