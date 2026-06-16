import XCTest
@testable import DocmostCore

final class MarkdownImportTests: XCTestCase {

    func testIsMarkdownFileMatchesByExtensionCaseInsensitively() {
        XCTAssertTrue(MarkdownImport.isMarkdownFile(URL(fileURLWithPath: "/tmp/notes.md")))
        XCTAssertTrue(MarkdownImport.isMarkdownFile(URL(fileURLWithPath: "/tmp/notes.markdown")))
        XCTAssertTrue(MarkdownImport.isMarkdownFile(URL(fileURLWithPath: "/tmp/NOTES.MD")))
        XCTAssertFalse(MarkdownImport.isMarkdownFile(URL(fileURLWithPath: "/tmp/notes.txt")))
        XCTAssertFalse(MarkdownImport.isMarkdownFile(URL(fileURLWithPath: "/tmp/notes.pdf")))
        XCTAssertFalse(MarkdownImport.isMarkdownFile(URL(fileURLWithPath: "/tmp/notes")))
    }

    func testImportableMarkdownFilesFiltersAndKeepsOrder() {
        let urls = [
            URL(fileURLWithPath: "/a.md"),
            URL(fileURLWithPath: "/b.txt"),
            URL(fileURLWithPath: "/c.markdown"),
            URL(fileURLWithPath: "/d.png")
        ]
        XCTAssertEqual(MarkdownImport.importableMarkdownFiles(from: urls).map { $0.lastPathComponent },
                       ["a.md", "c.markdown"])
    }

    func testSpaceSlugExtraction() {
        XCTAssertEqual(MarkdownImport.spaceSlug(fromPath: "/s/general"), "general")
        XCTAssertEqual(MarkdownImport.spaceSlug(fromPath: "/s/general/p/abc-123"), "general")
        XCTAssertEqual(MarkdownImport.spaceSlug(fromPath: "/s/my-space/"), "my-space")
        XCTAssertNil(MarkdownImport.spaceSlug(fromPath: "/home"))
        XCTAssertNil(MarkdownImport.spaceSlug(fromPath: "/"))
        XCTAssertNil(MarkdownImport.spaceSlug(fromPath: "/s"))
        XCTAssertNil(MarkdownImport.spaceSlug(fromPath: "/s/"))
        XCTAssertNil(MarkdownImport.spaceSlug(fromPath: "/share/xyz"))
        XCTAssertNil(MarkdownImport.spaceSlug(fromPath: "/share/s/leak"))
        XCTAssertNil(MarkdownImport.spaceSlug(fromPath: "/home/s/general"))
        XCTAssertNil(MarkdownImport.spaceSlug(fromPath: "/settings/s/x"))
    }

    func testImportScriptTargetsDocmostEndpoints() {
        let js = MarkdownImport.importMarkdownJS
        XCTAssertTrue(js.contains("/api/spaces/info"))
        XCTAssertTrue(js.contains("/api/pages/import"))
        XCTAssertTrue(js.contains("FormData"))
        XCTAssertTrue(js.contains("atob"))
        XCTAssertTrue(js.contains("credentials: 'include'"))
    }
}
