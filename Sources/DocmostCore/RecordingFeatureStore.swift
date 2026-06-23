import Foundation

// Broadcast when the recording feature toggle flips so the app surfaces (the floating panel,
// the menu-bar item, the View ▸ "Show Recorder Panel" item, and the Settings section) can
// add/remove themselves live. Posted by the Settings UI after persisting the new value.
public extension Notification.Name {
    static let recordingFeatureDidChange = Notification.Name("gitmost.recordingFeatureDidChange")
}

// Persists the "meeting recording" feature on/off flag in UserDefaults under a single key.
// The whole feature (capture, floating panel, menu-bar item, the View ▸ "Show Recorder Panel"
// item, and the Settings "Meeting recording" destination controls) is gated on this flag.
// Default: OFF (opt-in) — the feature stays hidden until the user enables it in Settings.
public final class RecordingFeatureStore {

    private static let defaultsKey = "recordingFeatureEnabled"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// True when the feature is enabled. Never-set defaults to false (opt-in).
    public var isEnabled: Bool {
        // object(forKey:) so "never set" (nil → false) is distinguishable from an explicit false.
        defaults.object(forKey: Self.defaultsKey) as? Bool ?? false
    }

    /// Enables or disables the feature (persisted). Posting the change notification is the
    /// caller's responsibility (the Settings UI), keeping this type free of UI side effects.
    public func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.defaultsKey)
    }
}
