import Foundation

// Persists the last visited URL per server in UserDefaults, so the app can reopen
// each tab where the user left off (instead of the server root) after a restart.
// Stored as a [serverID.uuidString: url.absoluteString] dictionary.
public final class LastLocationStore {

    private static let defaultsKey = "lastLocations"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func all() -> [String: String] {
        (defaults.dictionary(forKey: Self.defaultsKey) as? [String: String]) ?? [:]
    }

    private func setAll(_ dict: [String: String]) {
        defaults.set(dict, forKey: Self.defaultsKey)
    }

    // Remember `url` as the last location for the given server.
    public func save(_ url: URL, for serverID: UUID) {
        var dict = all()
        dict[serverID.uuidString] = url.absoluteString
        setAll(dict)
    }

    // The last remembered location for the server, if any.
    public func load(for serverID: UUID) -> URL? {
        guard let string = all()[serverID.uuidString] else { return nil }
        return URL(string: string)
    }

    // Forget the stored location for a server (e.g. when it is deleted or its URL changes).
    public func remove(for serverID: UUID) {
        var dict = all()
        dict.removeValue(forKey: serverID.uuidString)
        setAll(dict)
    }
}
