import Foundation

// The single configured destination for every finished recording: a server, a space,
// and an optional parent page. Each recording always creates a NEW child page under
// this parent (or at the space root when `parentPageId` is nil). Chosen once in
// Settings; there is no runtime picker.
public struct RecordingDestination: Codable, Equatable {
    public let serverId: UUID
    public let spaceId: String
    public let spaceName: String
    public let parentPageId: String?   // nil = space root
    public let parentTitle: String?    // nil = space root

    public init(serverId: UUID,
                spaceId: String,
                spaceName: String,
                parentPageId: String?,
                parentTitle: String?) {
        self.serverId = serverId
        self.spaceId = spaceId
        self.spaceName = spaceName
        self.parentPageId = parentPageId
        self.parentTitle = parentTitle
    }

    /// A short human label, e.g. "MySpace / Parent Page" or "MySpace (root)".
    public var displayLabel: String {
        if let parentTitle = parentTitle, !parentTitle.isEmpty {
            return "\(spaceName) / \(parentTitle)"
        }
        return "\(spaceName) (root)"
    }
}

// Persists the recording destination in UserDefaults as JSON under a single key.
public final class RecordingDestinationStore {

    private static let defaultsKey = "recordingDestination"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The configured destination, or nil when none is set / the stored value is corrupt.
    public var destination: RecordingDestination? {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode(RecordingDestination.self, from: data) else {
            return nil
        }
        return decoded
    }

    /// Stores the destination (JSON-encoded). A failed encode leaves the previous value intact.
    public func save(_ destination: RecordingDestination) {
        guard let data = try? JSONEncoder().encode(destination) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Forgets the configured destination.
    public func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
