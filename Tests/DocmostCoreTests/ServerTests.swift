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
}
