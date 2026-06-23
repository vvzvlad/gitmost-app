import XCTest
@testable import DocmostCore

final class RecordingDestinationStoreTests: XCTestCase {

    // Track suites created during a test so tearDown can wipe them.
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

    // MARK: - Round-trip

    func testSaveThenLoadRoundTripsWithParent() {
        let store = RecordingDestinationStore(defaults: makeSuite())
        let serverId = UUID()
        let dest = RecordingDestination(serverId: serverId,
                                        spaceId: "space-1",
                                        spaceName: "MySpace",
                                        parentPageId: "page-9",
                                        parentTitle: "Parent Page")
        store.save(dest)
        XCTAssertEqual(store.destination, dest)
    }

    func testSaveThenLoadRoundTripsWithoutParent() {
        let store = RecordingDestinationStore(defaults: makeSuite())
        let dest = RecordingDestination(serverId: UUID(),
                                        spaceId: "space-2",
                                        spaceName: "RootSpace",
                                        parentPageId: nil,
                                        parentTitle: nil)
        store.save(dest)
        let loaded = store.destination
        XCTAssertEqual(loaded, dest)
        XCTAssertNil(loaded?.parentPageId)
        XCTAssertNil(loaded?.parentTitle)
    }

    func testUnsetDestinationIsNil() {
        let store = RecordingDestinationStore(defaults: makeSuite())
        XCTAssertNil(store.destination)
    }

    func testSaveOverwrites() {
        let store = RecordingDestinationStore(defaults: makeSuite())
        let first = RecordingDestination(serverId: UUID(), spaceId: "s1", spaceName: "A",
                                         parentPageId: nil, parentTitle: nil)
        let second = RecordingDestination(serverId: UUID(), spaceId: "s2", spaceName: "B",
                                          parentPageId: "p2", parentTitle: "Second")
        store.save(first)
        store.save(second)
        XCTAssertEqual(store.destination, second)
    }

    // MARK: - Clear

    func testClear() {
        let store = RecordingDestinationStore(defaults: makeSuite())
        store.save(RecordingDestination(serverId: UUID(), spaceId: "s", spaceName: "S",
                                        parentPageId: nil, parentTitle: nil))
        XCTAssertNotNil(store.destination)
        store.clear()
        XCTAssertNil(store.destination)
    }

    // MARK: - Persistence across instances

    func testPersistsAcrossStoreInstances() {
        // Simulates an app restart: a fresh store over the same defaults sees the value.
        let defaults = makeSuite()
        let dest = RecordingDestination(serverId: UUID(), spaceId: "s", spaceName: "S",
                                        parentPageId: "p", parentTitle: "P")
        RecordingDestinationStore(defaults: defaults).save(dest)
        XCTAssertEqual(RecordingDestinationStore(defaults: defaults).destination, dest)
    }

    // MARK: - displayLabel

    func testDisplayLabelWithParent() {
        let dest = RecordingDestination(serverId: UUID(), spaceId: "s", spaceName: "MySpace",
                                        parentPageId: "p", parentTitle: "Parent Page")
        XCTAssertEqual(dest.displayLabel, "MySpace / Parent Page")
    }

    func testDisplayLabelAtRoot() {
        let dest = RecordingDestination(serverId: UUID(), spaceId: "s", spaceName: "MySpace",
                                        parentPageId: nil, parentTitle: nil)
        XCTAssertEqual(dest.displayLabel, "MySpace (root)")
    }

    func testDisplayLabelEmptyParentTitleFallsBackToRoot() {
        // A parent id with an empty title should still read as root rather than "Space / ".
        let dest = RecordingDestination(serverId: UUID(), spaceId: "s", spaceName: "MySpace",
                                        parentPageId: "p", parentTitle: "")
        XCTAssertEqual(dest.displayLabel, "MySpace (root)")
    }
}
