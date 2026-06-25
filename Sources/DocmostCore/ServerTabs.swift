import Foundation

/// Pure, UI-independent model of the open page ("browser") tabs per server: an ordered
/// list of page-tab ids and the active tab for each server. Holds no WebKit/AppKit state —
/// the UI maps tab ids to web views separately. Fully unit-tested in DocmostCore.
public struct ServerTabs {
    // server id -> ordered page-tab ids
    private var order: [UUID: [UUID]] = [:]
    // server id -> active page-tab id
    private var activeByServer: [UUID: UUID] = [:]

    public init() {}

    /// Server ids that currently have at least one page tab (in no particular order).
    public func serverIDs() -> [UUID] {
        Array(order.keys)
    }

    /// Ordered page-tab ids for a server ([] if none).
    public func tabs(for server: UUID) -> [UUID] {
        order[server] ?? []
    }

    /// Active page-tab id for a server, if any.
    public func activeTab(for server: UUID) -> UUID? {
        activeByServer[server]
    }

    public func count(for server: UUID) -> Int {
        order[server]?.count ?? 0
    }

    public func hasTabs(for server: UUID) -> Bool {
        !(order[server]?.isEmpty ?? true)
    }

    public func contains(_ tab: UUID, in server: UUID) -> Bool {
        order[server]?.contains(tab) ?? false
    }

    /// Append a tab to a server. When `makeActive` is true (default) it becomes the active tab.
    public mutating func addTab(_ tab: UUID, to server: UUID, makeActive: Bool = true) {
        order[server, default: []].append(tab)
        if makeActive {
            activeByServer[server] = tab
        }
    }

    /// Make `tab` active for `server` (no-op if the tab is not in that server).
    public mutating func setActiveTab(_ tab: UUID, for server: UUID) {
        guard contains(tab, in: server) else { return }
        activeByServer[server] = tab
    }

    /// Remove `tab` from `server`. Returns the active tab id AFTER removal (the neighbor that
    /// became active when the closed tab was active, or the unchanged active id).
    /// NEVER removes the last remaining tab: when the server has <= 1 tab this is a no-op and
    /// returns the current active id. Returns nil only when the server/tab is unknown.
    @discardableResult
    public mutating func closeTab(_ tab: UUID, from server: UUID) -> UUID? {
        guard var ids = order[server], let index = ids.firstIndex(of: tab) else { return nil }

        // Never remove the last remaining tab.
        guard ids.count > 1 else { return activeByServer[server] }

        let wasActive = activeByServer[server] == tab
        ids.remove(at: index)
        order[server] = ids

        if wasActive {
            // The neighbor that becomes active: the next tab, or the previous one if the
            // last tab was closed.
            let newActiveIndex = min(index, ids.count - 1)
            let newActive = ids[newActiveIndex]
            activeByServer[server] = newActive
            return newActive
        }

        // Closing a non-active tab leaves the active unchanged.
        return activeByServer[server]
    }

    /// Remove ALL tabs of a server (it was deleted, or its URL changed). Returns the removed
    /// tab ids so the caller can tear down their web views.
    @discardableResult
    public mutating func removeServer(_ server: UUID) -> [UUID] {
        let removed = order[server] ?? []
        order.removeValue(forKey: server)
        activeByServer.removeValue(forKey: server)
        return removed
    }
}
