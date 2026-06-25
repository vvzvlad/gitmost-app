import Foundation
import DocmostCore

// Owns the per-server page-tab model (DocmostCore.ServerTabs) AND the id->WebTab lifecycle
// together, so the two can never drift. Exposes intent-level operations (open a server, new
// tab, select, close, remove a server); the hosting view controller does only view
// installation and window-chrome updates. Each WebTab's navigation/title callbacks are wired
// here at creation and forwarded up via onNavigationStateChanged / onTitleChanged, identified
// by (serverID, tabID).
final class PageTabController {

    // Pure, UI-independent order + active state per server.
    private var model = ServerTabs()
    // page-tab id -> the kept-alive WebTab backing it.
    private var webTabs: [UUID: WebTab] = [:]

    // Set once by the host. Fire on the main thread (forwarded from WebTab's own callbacks).
    var onNavigationStateChanged: ((_ serverID: UUID, _ tabID: UUID, _ webTab: WebTab) -> Void)?
    var onTitleChanged: ((_ serverID: UUID, _ tabID: UUID, _ webTab: WebTab) -> Void)?

    // Result of a close attempt, so the host can react (switch the visible tab when needed).
    struct CloseResult {
        // false when the close was a no-op (last remaining tab, or unknown server/tab).
        let didClose: Bool
        // The closed tab was its server's active tab.
        let closedActiveTab: Bool
        // The tab that became active after closing the active tab (nil otherwise).
        let newActiveTab: WebTab?
    }

    // MARK: - Queries

    func tabs(for server: UUID) -> [UUID] { model.tabs(for: server) }
    func activeTab(for server: UUID) -> UUID? { model.activeTab(for: server) }
    func count(for server: UUID) -> Int { model.count(for: server) }
    func hasTabs(for server: UUID) -> Bool { model.hasTabs(for: server) }
    func serverIDs() -> [UUID] { model.serverIDs() }

    func webTab(_ id: UUID) -> WebTab? { webTabs[id] }

    // The active tab's WebTab for a server, if any.
    func activeWebTab(for server: UUID) -> WebTab? {
        model.activeTab(for: server).flatMap { webTabs[$0] }
    }

    // A WebTab to represent a server for bridge/recording calls: prefer the active tab, else
    // the first tab.
    func representativeTab(for server: UUID) -> WebTab? {
        if let a = model.activeTab(for: server), let t = webTabs[a] { return t }
        return model.tabs(for: server).first.flatMap { webTabs[$0] }
    }

    // Ordered (id, WebTab) pairs for a server, skipping any id without a backing WebTab.
    func tabWebPairs(for server: UUID) -> [(id: UUID, webTab: WebTab)] {
        model.tabs(for: server).compactMap { id in webTabs[id].map { (id: id, webTab: $0) } }
    }

    // All live WebTabs (no particular order). Used for app-wide zoom and the no-destination
    // recording fallback.
    var allWebTabs: [WebTab] { Array(webTabs.values) }

    // MARK: - Mutations

    // Ensure the server has at least one page tab, creating its first one at `startURL`
    // (evaluated lazily, only when a tab must be created) and making it active. Returns the
    // server's active WebTab to display.
    @discardableResult
    func openServer(_ server: Server, startURL: @autoclosure () -> URL) -> WebTab? {
        if !model.hasTabs(for: server.id) {
            let made = makeWebTab(server: server, startURL: startURL())
            model.addTab(made.id, to: server.id) // makeActive defaults to true
        }
        return activeWebTab(for: server.id)
    }

    // Open a NEW page tab for a server at `url` and make it active. Returns its WebTab.
    @discardableResult
    func newTab(for server: Server, at url: URL) -> WebTab {
        let made = makeWebTab(server: server, startURL: url)
        model.addTab(made.id, to: server.id) // makeActive defaults to true
        return made.webTab
    }

    // Make `tabID` the active tab of `server` and return its WebTab. nil if not present.
    func selectTab(_ tabID: UUID, in server: UUID) -> WebTab? {
        guard model.contains(tabID, in: server), let tab = webTabs[tabID] else { return nil }
        model.setActiveTab(tabID, for: server)
        return tab
    }

    // Close `tabID` of `server`, never the last remaining tab. Tears down its WebTab and
    // updates the model. See CloseResult.
    func closeTab(_ tabID: UUID, in server: UUID) -> CloseResult {
        guard model.count(for: server) > 1, model.contains(tabID, in: server) else {
            return CloseResult(didClose: false, closedActiveTab: false, newActiveTab: nil)
        }
        let wasActive = model.activeTab(for: server) == tabID
        webTabs[tabID]?.tearDown()
        webTabs.removeValue(forKey: tabID)
        let newActiveID = model.closeTab(tabID, from: server)
        let newActive = newActiveID.flatMap { webTabs[$0] }
        return CloseResult(didClose: true, closedActiveTab: wasActive, newActiveTab: newActive)
    }

    // Remove ALL page tabs of a server (deleted, or its URL changed), tearing down their
    // WebTabs. The host is responsible for any associated cleanup (e.g. saved location).
    func removeServer(_ server: UUID) {
        for tabID in model.removeServer(server) {
            webTabs[tabID]?.tearDown()
            webTabs.removeValue(forKey: tabID)
        }
    }

    // MARK: - WebTab creation

    // Builds a kept-alive WebTab for a fresh page-tab id, wires its navigation/title callbacks
    // to forward up (tagged with serverID + tabID), registers it, and returns the new id + tab.
    private func makeWebTab(server: Server, startURL: URL) -> (id: UUID, webTab: WebTab) {
        let tabID = UUID()
        let webTab = WebTab(server: server, startURL: startURL,
                            customJS: UserScripts.js, customCSS: UserScripts.css)
        webTab.onNavigationStateChanged = { [weak self, weak webTab] in
            guard let self, let webTab else { return }
            self.onNavigationStateChanged?(server.id, tabID, webTab)
        }
        webTab.onTitleChanged = { [weak self, weak webTab] in
            guard let self, let webTab else { return }
            self.onTitleChanged?(server.id, tabID, webTab)
        }
        webTabs[tabID] = webTab
        return (tabID, webTab)
    }
}
