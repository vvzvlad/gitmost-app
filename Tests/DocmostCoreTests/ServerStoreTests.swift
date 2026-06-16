import XCTest
@testable import DocmostCore

final class ServerStoreTests: XCTestCase {

    // Track suites created during a test so tearDown can wipe them.
    private var createdSuiteNames: [String] = []

    override func tearDown() {
        // Clear every isolated suite so tests never leak state into one another
        // or touch the real standard defaults.
        for name in createdSuiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        createdSuiteNames.removeAll()
        super.tearDown()
    }

    private func makeSuite() -> UserDefaults {
        // Unique suite name per call; UUID keeps tests isolated.
        let name = "DocmostCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        createdSuiteNames.append(name)
        return defaults
    }

    // MARK: - normalizeURL

    func testNormalizeBareHostGetsHTTPS() {
        let url = ServerStore.normalizeURL("docs.example.com")
        XCTAssertEqual(url?.absoluteString, "https://docs.example.com")
    }

    func testNormalizeKeepsExplicitHTTP() {
        let url = ServerStore.normalizeURL("http://localhost:3000")
        XCTAssertEqual(url?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(url?.scheme, "http")
    }

    func testNormalizePreservesPathAndQuery() {
        let url = ServerStore.normalizeURL("https://x.test/path?q=1")
        XCTAssertEqual(url?.absoluteString, "https://x.test/path?q=1")
        XCTAssertEqual(url?.path, "/path")
        XCTAssertEqual(url?.query, "q=1")
    }

    func testNormalizeTrimsWhitespace() {
        let url = ServerStore.normalizeURL("  docs.example.com  ")
        XCTAssertEqual(url?.absoluteString, "https://docs.example.com")
    }

    func testNormalizeRejectsInvalidInput() {
        XCTAssertNil(ServerStore.normalizeURL(""))
        XCTAssertNil(ServerStore.normalizeURL("   "))
        XCTAssertNil(ServerStore.normalizeURL("ftp://host"))
        XCTAssertNil(ServerStore.normalizeURL("javascript:alert(1)"))
        XCTAssertNil(ServerStore.normalizeURL("https://"))
    }

    // MARK: - Persistence round-trip

    func testPersistenceRoundTrip() {
        let suite = makeSuite()

        let store = ServerStore(defaults: suite)
        store.add(name: "Docs", urlString: "https://docs.example.com")
        XCTAssertEqual(store.servers.count, 1)

        // A brand-new store backed by the same suite must reload the saved server.
        let reloaded = ServerStore(defaults: suite)
        XCTAssertEqual(reloaded.servers.count, 1)
        XCTAssertEqual(reloaded.servers.first?.name, "Docs")
        XCTAssertEqual(reloaded.servers.first?.url.absoluteString, "https://docs.example.com")
    }

    // MARK: - add / update / remove

    func testAddUpdateRemove() {
        let suite = makeSuite()
        let store = ServerStore(defaults: suite)

        store.add(name: "Alpha", urlString: "https://alpha.test")
        store.add(name: "Beta", urlString: "https://beta.test")
        XCTAssertEqual(store.servers.count, 2)

        // Update the first server's name and url.
        let first = store.servers[0]
        store.update(Server(id: first.id, name: "Alpha2", url: URL(string: "https://alpha2.test")!))
        XCTAssertEqual(store.servers[0].name, "Alpha2")
        XCTAssertEqual(store.servers[0].url.absoluteString, "https://alpha2.test")

        // Remove the second server by id.
        let secondID = store.servers[1].id
        store.remove(id: secondID)
        XCTAssertEqual(store.servers.count, 1)
        XCTAssertEqual(store.servers.first?.name, "Alpha2")
    }

    func testAddIgnoresInvalidURL() {
        let suite = makeSuite()
        let store = ServerStore(defaults: suite)

        store.add(name: "x", urlString: "ftp://nope")
        XCTAssertTrue(store.servers.isEmpty)
    }

    func testBlankNameFallsBackToHost() {
        let suite = makeSuite()
        let store = ServerStore(defaults: suite)

        store.add(name: "  ", urlString: "docs.example.com")
        XCTAssertEqual(store.servers.count, 1)
        XCTAssertEqual(store.servers.first?.name, "docs.example.com")
    }

    // MARK: - move (reorder)

    func testMoveForwardReordersAndPersists() {
        let suite = makeSuite()
        let store = ServerStore(defaults: suite)
        store.add(name: "A", urlString: "https://a.test")
        store.add(name: "B", urlString: "https://b.test")
        store.add(name: "C", urlString: "https://c.test")

        // Drag A (row 0) to the gap after C (NSTableView drop index 3) -> [B, C, A].
        store.move(from: 0, to: 3)
        XCTAssertEqual(store.servers.map { $0.name }, ["B", "C", "A"])

        // The new order must survive a reload from the same defaults suite.
        let reloaded = ServerStore(defaults: suite)
        XCTAssertEqual(reloaded.servers.map { $0.name }, ["B", "C", "A"])
    }

    func testMoveBackwardReorders() {
        let suite = makeSuite()
        let store = ServerStore(defaults: suite)
        store.add(name: "A", urlString: "https://a.test")
        store.add(name: "B", urlString: "https://b.test")
        store.add(name: "C", urlString: "https://c.test")

        // Drag C (row 2) to the gap before A (drop index 0) -> [C, A, B].
        store.move(from: 2, to: 0)
        XCTAssertEqual(store.servers.map { $0.name }, ["C", "A", "B"])
    }

    func testMoveToOwnSlotIsNoOp() {
        let suite = makeSuite()
        let store = ServerStore(defaults: suite)
        store.add(name: "A", urlString: "https://a.test")
        store.add(name: "B", urlString: "https://b.test")

        // Dropping into the gap right after itself must not change the order.
        store.move(from: 0, to: 1)
        XCTAssertEqual(store.servers.map { $0.name }, ["A", "B"])
    }

    func testMoveIgnoresOutOfBoundsIndexes() {
        let suite = makeSuite()
        let store = ServerStore(defaults: suite)
        store.add(name: "A", urlString: "https://a.test")
        store.add(name: "B", urlString: "https://b.test")

        store.move(from: 5, to: 0)   // invalid source index
        store.move(from: 0, to: 9)   // invalid destination index
        XCTAssertEqual(store.servers.map { $0.name }, ["A", "B"])
    }

    // MARK: - Notification

    func testAddPostsNotification() {
        let suite = makeSuite()
        let store = ServerStore(defaults: suite)

        let expectation = expectation(forNotification: .serversDidChange, object: store, handler: nil)
        store.add(name: "Notify", urlString: "https://notify.test")
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Server Codable round-trip

    func testServerCodableRoundTrip() throws {
        let original = Server(name: "RoundTrip", url: URL(string: "https://round.test/path")!)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Server.self, from: data)
        XCTAssertEqual(original, decoded)
    }
}
