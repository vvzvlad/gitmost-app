import XCTest
@testable import DocmostCore

final class RecordingFeatureStoreTests: XCTestCase {

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

    // MARK: - Default (opt-in)

    func testDefaultUnsetIsDisabled() {
        let store = RecordingFeatureStore(defaults: makeSuite())
        XCTAssertFalse(store.isEnabled)
    }

    // MARK: - Toggling

    func testSetEnabledTrue() {
        let store = RecordingFeatureStore(defaults: makeSuite())
        store.setEnabled(true)
        XCTAssertTrue(store.isEnabled)
    }

    func testSetEnabledFalseAfterTrue() {
        let store = RecordingFeatureStore(defaults: makeSuite())
        store.setEnabled(true)
        XCTAssertTrue(store.isEnabled)
        store.setEnabled(false)
        XCTAssertFalse(store.isEnabled)
    }

    // MARK: - Persistence across instances

    func testPersistsAcrossStoreInstances() {
        // Simulates an app restart: a fresh store over the same defaults sees the value.
        let defaults = makeSuite()
        RecordingFeatureStore(defaults: defaults).setEnabled(true)
        XCTAssertTrue(RecordingFeatureStore(defaults: defaults).isEnabled)
    }
}
