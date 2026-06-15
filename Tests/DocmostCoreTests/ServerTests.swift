import XCTest
@testable import DocmostCore

final class ServerTests: XCTestCase {

    private func server(_ urlString: String) -> Server {
        Server(name: "S", url: URL(string: urlString)!)
    }

    func testSameHostIsInternal() {
        let s = server("https://docs.example.com")
        XCTAssertFalse(s.isExternalURL(URL(string: "https://docs.example.com/page/123")))
    }

    func testDifferentHostIsExternal() {
        let s = server("https://docs.example.com")
        XCTAssertTrue(s.isExternalURL(URL(string: "https://alibaba.com/product")))
    }

    func testHostComparisonIsCaseInsensitive() {
        let s = server("https://Docs.Example.com")
        XCTAssertFalse(s.isExternalURL(URL(string: "https://docs.example.com/x")))
    }

    func testSubdomainIsExternal() {
        // A different subdomain is a different host (e.g. an SSO provider).
        let s = server("https://docs.example.com")
        XCTAssertTrue(s.isExternalURL(URL(string: "https://accounts.google.com")))
    }

    func testNilURLIsInternal() {
        let s = server("https://docs.example.com")
        XCTAssertFalse(s.isExternalURL(nil))
    }

    func testSameHostDifferentSchemeOrPortStaysInternalByHost() {
        // Only the host is compared; scheme/port differences do not make it external.
        let s = server("https://docs.example.com")
        XCTAssertFalse(s.isExternalURL(URL(string: "http://docs.example.com:3000/login")))
    }

    func testInternalPageURLSameHost() {
        let s = server("https://docs.example.com")
        XCTAssertTrue(s.isInternalPageURL(URL(string: "https://docs.example.com/s/general/p/abc")))
    }

    func testInternalPageURLDifferentHostIsNotInternal() {
        let s = server("https://docs.example.com")
        XCTAssertFalse(s.isInternalPageURL(URL(string: "https://alibaba.com/x")))
    }

    func testInternalPageURLRejectsNonWebSchemes() {
        let s = server("https://docs.example.com")
        XCTAssertFalse(s.isInternalPageURL(URL(string: "about:blank")))
        XCTAssertFalse(s.isInternalPageURL(URL(string: "file:///tmp/x.html")))
    }

    func testInternalPageURLNilIsFalse() {
        let s = server("https://docs.example.com")
        XCTAssertFalse(s.isInternalPageURL(nil))
    }

    func testSharePageURLDetected() {
        let s = server("https://docs.example.com")
        XCTAssertTrue(s.isSharePageURL(URL(string: "https://docs.example.com/share/hkgh6ful5c/p/analiz-591")))
    }

    func testEditablePageIsNotShare() {
        let s = server("https://docs.example.com")
        XCTAssertFalse(s.isSharePageURL(URL(string: "https://docs.example.com/s/general/p/analiz-591")))
    }

    func testPageSlugContainingShareWordIsNotShare() {
        // Only the "/share/" path prefix counts, not a slug that merely contains "share".
        let s = server("https://docs.example.com")
        XCTAssertFalse(s.isSharePageURL(URL(string: "https://docs.example.com/s/general/p/share-tips-xyz")))
    }

    func testSharePageOnDifferentHostIsNotShare() {
        // A "/share/" path on a foreign host is external, not an internal share page.
        let s = server("https://docs.example.com")
        XCTAssertFalse(s.isSharePageURL(URL(string: "https://evil.com/share/abc/p/x")))
    }

    func testSharePageNilIsFalse() {
        let s = server("https://docs.example.com")
        XCTAssertFalse(s.isSharePageURL(nil))
    }

    func testSharePageURLWithQueryAndFragment() {
        // URL.path drops query/fragment, so the "/share/" prefix still matches.
        let s = server("https://docs.example.com")
        XCTAssertTrue(s.isSharePageURL(URL(string: "https://docs.example.com/share/abc/p/x?token=1")))
        XCTAssertTrue(s.isSharePageURL(URL(string: "https://docs.example.com/share/abc/p/x#section")))
    }

    func testShareSegmentWithoutTrailingSlashIsNotShare() {
        let s = server("https://docs.example.com")
        XCTAssertFalse(s.isSharePageURL(URL(string: "https://docs.example.com/share")))
    }

    func testSharePageRejectsNonWebScheme() {
        let s = server("https://docs.example.com")
        XCTAssertFalse(s.isSharePageURL(URL(string: "about:blank")))
    }
}
