import XCTest
@testable import DocmostCore

final class LastLocationStoreTests: XCTestCase {

    private var createdSuiteNames: [String] = []

    override func tearDown() {
        for name in createdSuiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        createdSuiteNames.removeAll()
        super.tearDown()
    }

    private func makeSuite() -> UserDefaults {
        let name = "DocmostCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        createdSuiteNames.append(name)
        return defaults
    }

    func testSaveThenLoadRoundTrips() {
        let store = LastLocationStore(defaults: makeSuite())
        let id = UUID()
        let url = URL(string: "https://docs.example.com/s/general/p/page-abc")!
        store.save(url, for: id)
        XCTAssertEqual(store.load(for: id), url)
    }

    func testLoadUnknownIsNil() {
        let store = LastLocationStore(defaults: makeSuite())
        XCTAssertNil(store.load(for: UUID()))
    }

    func testSaveOverwrites() {
        let store = LastLocationStore(defaults: makeSuite())
        let id = UUID()
        store.save(URL(string: "https://docs.example.com/a")!, for: id)
        store.save(URL(string: "https://docs.example.com/b")!, for: id)
        XCTAssertEqual(store.load(for: id)?.absoluteString, "https://docs.example.com/b")
    }

    func testRemove() {
        let store = LastLocationStore(defaults: makeSuite())
        let id = UUID()
        store.save(URL(string: "https://docs.example.com/a")!, for: id)
        store.remove(for: id)
        XCTAssertNil(store.load(for: id))
    }

    func testServersAreIndependent() {
        let store = LastLocationStore(defaults: makeSuite())
        let a = UUID(), b = UUID()
        store.save(URL(string: "https://docs.example.com/a")!, for: a)
        store.save(URL(string: "https://docs.example.com/b")!, for: b)
        XCTAssertEqual(store.load(for: a)?.absoluteString, "https://docs.example.com/a")
        XCTAssertEqual(store.load(for: b)?.absoluteString, "https://docs.example.com/b")
    }

    func testPersistsAcrossStoreInstances() {
        // Simulates an app restart: a fresh store over the same defaults sees the value.
        let defaults = makeSuite()
        let id = UUID()
        LastLocationStore(defaults: defaults).save(URL(string: "https://docs.example.com/x")!, for: id)
        XCTAssertEqual(LastLocationStore(defaults: defaults).load(for: id)?.absoluteString,
                       "https://docs.example.com/x")
    }
}
