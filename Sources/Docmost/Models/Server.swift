import Foundation

// A single Docmost server configured by the user.
struct Server: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var url: URL

    // Default `id` to a fresh UUID so callers only need to supply name + url.
    init(id: UUID = UUID(), name: String, url: URL) {
        self.id = id
        self.name = name
        self.url = url
    }
}
