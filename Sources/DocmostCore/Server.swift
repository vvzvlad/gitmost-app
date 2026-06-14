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
