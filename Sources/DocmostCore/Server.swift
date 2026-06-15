import Foundation

// A single Docmost server configured by the user.
public struct Server: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var url: URL

    // Default `id` to a fresh UUID so callers only need to supply name + url.
    public init(id: UUID = UUID(), name: String, url: URL) {
        self.id = id
        self.name = name
        self.url = url
    }
}

public extension Server {
    /// True when `url` is on a different host than this server — i.e. an external site.
    /// The comparison is case-insensitive; a `url` (or the server URL) without a host is
    /// treated as internal (returns false).
    func isExternalURL(_ url: URL?) -> Bool {
        guard let host = url?.host, let serverHost = self.url.host else { return false }
        return host.caseInsensitiveCompare(serverHost) != .orderedSame
    }

    /// True when `url` is a real navigable page on this server: same host as the
    /// server (case-insensitive) and an http/https scheme. Used to decide whether a
    /// location is worth remembering and restoring. A nil/host-less or non-web URL
    /// (e.g. `about:blank`, `file:`) returns false.
    func isInternalPageURL(_ url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              let serverHost = self.url.host else { return false }
        return host.caseInsensitiveCompare(serverHost) == .orderedSame
    }
}
