import XCTest
@testable import DocmostCore

final class ServerTabsTests: XCTestCase {

    func testAddTabPreservesOrderAndFirstBecomesActive() {
        var model = ServerTabs()
        let server = UUID()
        let a = UUID(), b = UUID(), c = UUID()

        model.addTab(a, to: server)
        XCTAssertEqual(model.activeTab(for: server), a)

        model.addTab(b, to: server)
        model.addTab(c, to: server)

        XCTAssertEqual(model.tabs(for: server), [a, b, c])
        // Each default-active add makes the newest tab active.
        XCTAssertEqual(model.activeTab(for: server), c)
        XCTAssertEqual(model.count(for: server), 3)
    }

    func testAddTabMakeActiveFalseKeepsPreviousActive() {
        var model = ServerTabs()
        let server = UUID()
        let a = UUID(), b = UUID()

        model.addTab(a, to: server)
        model.addTab(b, to: server, makeActive: false)

        XCTAssertEqual(model.tabs(for: server), [a, b])
        XCTAssertEqual(model.activeTab(for: server), a)
    }

    func testSetActiveTabPresentAndAbsent() {
        var model = ServerTabs()
        let server = UUID()
        let a = UUID(), b = UUID()
        let absent = UUID()

        model.addTab(a, to: server)
        model.addTab(b, to: server)
        XCTAssertEqual(model.activeTab(for: server), b)

        model.setActiveTab(a, for: server)
        XCTAssertEqual(model.activeTab(for: server), a)

        // No-op for a tab that is not in this server.
        model.setActiveTab(absent, for: server)
        XCTAssertEqual(model.activeTab(for: server), a)
    }

    func testCloseNonActiveTabLeavesActiveUnchanged() {
        var model = ServerTabs()
        let server = UUID()
        let a = UUID(), b = UUID(), c = UUID()
        model.addTab(a, to: server)
        model.addTab(b, to: server)
        model.addTab(c, to: server)
        model.setActiveTab(c, for: server)

        let newActive = model.closeTab(a, from: server)
        XCTAssertEqual(newActive, c)
        XCTAssertEqual(model.activeTab(for: server), c)
        XCTAssertEqual(model.tabs(for: server), [b, c])
    }

    func testCloseActiveMiddleTabActivatesNext() {
        var model = ServerTabs()
        let server = UUID()
        let a = UUID(), b = UUID(), c = UUID()
        model.addTab(a, to: server)
        model.addTab(b, to: server)
        model.addTab(c, to: server)
        model.setActiveTab(b, for: server)

        // Closing the active middle tab activates the next tab (c).
        let newActive = model.closeTab(b, from: server)
        XCTAssertEqual(newActive, c)
        XCTAssertEqual(model.activeTab(for: server), c)
        XCTAssertEqual(model.tabs(for: server), [a, c])
    }

    func testCloseActiveLastTabActivatesPrevious() {
        var model = ServerTabs()
        let server = UUID()
        let a = UUID(), b = UUID(), c = UUID()
        model.addTab(a, to: server)
        model.addTab(b, to: server)
        model.addTab(c, to: server)
        model.setActiveTab(c, for: server)

        // Closing the active last tab activates the previous tab (b).
        let newActive = model.closeTab(c, from: server)
        XCTAssertEqual(newActive, b)
        XCTAssertEqual(model.activeTab(for: server), b)
        XCTAssertEqual(model.tabs(for: server), [a, b])
    }

    func testCloseLastRemainingTabIsNoOp() {
        var model = ServerTabs()
        let server = UUID()
        let a = UUID()
        model.addTab(a, to: server)

        let result = model.closeTab(a, from: server)
        XCTAssertEqual(result, a)
        XCTAssertEqual(model.tabs(for: server), [a])
        XCTAssertEqual(model.activeTab(for: server), a)
        XCTAssertEqual(model.count(for: server), 1)
    }

    func testCloseUnknownServerOrTabReturnsNil() {
        var model = ServerTabs()
        let server = UUID()
        let a = UUID()
        model.addTab(a, to: server)

        // Unknown server.
        XCTAssertNil(model.closeTab(a, from: UUID()))
        // Unknown tab in a known server.
        XCTAssertNil(model.closeTab(UUID(), from: server))
    }

    func testRemoveServerReturnsAllTabsInOrderAndClears() {
        var model = ServerTabs()
        let server = UUID()
        let a = UUID(), b = UUID(), c = UUID()
        model.addTab(a, to: server)
        model.addTab(b, to: server)
        model.addTab(c, to: server)

        let removed = model.removeServer(server)
        XCTAssertEqual(removed, [a, b, c])
        XCTAssertEqual(model.tabs(for: server), [])
        XCTAssertNil(model.activeTab(for: server))
        XCTAssertFalse(model.hasTabs(for: server))
        XCTAssertEqual(model.count(for: server), 0)
    }

    func testRemoveUnknownServerReturnsEmpty() {
        var model = ServerTabs()
        XCTAssertEqual(model.removeServer(UUID()), [])
    }

    func testCountHasTabsContains() {
        var model = ServerTabs()
        let server = UUID()
        let a = UUID(), b = UUID()
        let absent = UUID()

        XCTAssertEqual(model.count(for: server), 0)
        XCTAssertFalse(model.hasTabs(for: server))
        XCTAssertFalse(model.contains(a, in: server))

        model.addTab(a, to: server)
        model.addTab(b, to: server)

        XCTAssertEqual(model.count(for: server), 2)
        XCTAssertTrue(model.hasTabs(for: server))
        XCTAssertTrue(model.contains(a, in: server))
        XCTAssertTrue(model.contains(b, in: server))
        XCTAssertFalse(model.contains(absent, in: server))
    }

    func testTwoServersAreIndependent() {
        var model = ServerTabs()
        let s1 = UUID(), s2 = UUID()
        let a = UUID(), b = UUID(), c = UUID()

        model.addTab(a, to: s1)
        model.addTab(b, to: s1)
        model.addTab(c, to: s2)

        XCTAssertEqual(model.tabs(for: s1), [a, b])
        XCTAssertEqual(model.tabs(for: s2), [c])
        XCTAssertEqual(model.activeTab(for: s1), b)
        XCTAssertEqual(model.activeTab(for: s2), c)

        // Removing one server leaves the other intact.
        model.removeServer(s1)
        XCTAssertFalse(model.hasTabs(for: s1))
        XCTAssertEqual(model.tabs(for: s2), [c])
        XCTAssertEqual(model.activeTab(for: s2), c)
    }

    func testServerIDsReflectsServersWithTabs() {
        var model = ServerTabs()
        let s1 = UUID(), s2 = UUID()
        XCTAssertTrue(model.serverIDs().isEmpty)

        model.addTab(UUID(), to: s1)
        model.addTab(UUID(), to: s2)
        XCTAssertEqual(Set(model.serverIDs()), Set([s1, s2]))

        model.removeServer(s1)
        XCTAssertEqual(model.serverIDs(), [s2])
    }
}
