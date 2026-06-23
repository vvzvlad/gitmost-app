import Foundation

// Posted on every recording-state transition so any UI surface (the menu via the
// responder chain, plus Stage B's floating panel and menu-bar item) can refresh.
extension Notification.Name {
    static let recordingStateDidChange = Notification.Name("gitmost.recordingStateDidChange")
}

// App-level single source of truth for a meeting recording. ONE recording exists at a
// time; the menu, the floating panel and the menu-bar item (Stage B) all drive this
// shared instance so they never disagree about state.
//
// The app (AppDelegate) wires the three closures below — `deliverFile`,
// `isDeliveryAvailable` and `presentError` — to bridge into the UI layer. They are all
// invoked on the main thread. The recorder itself is `AudioRecorder`, which is gated to
// macOS 14.2+, so it is held as `AnyObject?` and only ever created/used behind an
// availability guard. Everything public here runs on the main thread.
final class RecordingController {

    enum State {
        case idle
        case recording
        case paused
    }

    static let shared = RecordingController()
    private init() {}

    // Main-thread only. The single authoritative recording state.
    private(set) var state: State = .idle

    // Underlying recorder. Held as AnyObject because AudioRecorder is @available(macOS
    // 14.2, *) and the app targets 14.0; only ever created/cast behind an availability
    // guard. nil whenever state == .idle.
    private var recorder: AnyObject?

    // True from the moment stop() begins until its completion runs, mirroring the
    // re-entrancy discipline that previously lived in MainViewController: it prevents a
    // second toggle() from double-stopping a recording that is still finalizing.
    private var isStopping = false

    // Wall-clock bookkeeping for elapsedTime. `startDate` is set when recording begins;
    // `accumulatedPaused` collects the total duration spent paused; `pauseDate` marks the
    // moment the current pause began (nil while not paused).
    private var startDate: Date?
    private var accumulatedPaused: TimeInterval = 0
    private var pauseDate: Date?

    // MARK: - App wiring (all invoked on the main thread)

    // Called on stop success with the finished .m4a file.
    var deliverFile: ((URL) -> Void)?
    // True when an open page can receive the file (a gitmost page is open).
    var isDeliveryAvailable: (() -> Bool)?
    // Presents a user-facing error (title + message).
    var presentError: ((_ title: String, _ message: String) -> Void)?

    // MARK: - Derived state

    // Wall-clock time since start, minus any time spent paused. 0 when idle.
    var elapsedTime: TimeInterval {
        assertMainThread()
        guard let startDate = startDate else { return 0 }
        // When currently paused, exclude the in-progress pause span as well.
        let ongoingPause = pauseDate.map { Date().timeIntervalSince($0) } ?? 0
        let elapsed = Date().timeIntervalSince(startDate) - accumulatedPaused - ongoingPause
        return max(0, elapsed)
    }

    // Recent audio peak in 0...1, read from the recorder's thread-safe snapshot. 0 when
    // idle or paused.
    var audioLevel: Float {
        assertMainThread()
        guard state == .recording else { return 0 }
        if #available(macOS 14.2, *), let recorder = recorder as? AudioRecorder {
            return recorder.currentLevel
        }
        return 0
    }

    // false on macOS < 14.2 (the Core Audio process-tap API the recorder needs).
    var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    // True when a new recording can be started right now: the OS supports capture and a
    // page is open to receive the file. The UI uses this to enable/disable the Start
    // control so the user can't start with no open page / on macOS < 14.2.
    var canStart: Bool {
        assertMainThread()
        return isSupported && (isDeliveryAvailable?() ?? false)
    }

    // MARK: - Public mutators (main thread only)

    // idle -> start, recording/paused -> stop.
    func toggle() {
        assertMainThread()
        switch state {
        case .idle:
            start()
        case .recording, .paused:
            stop()
        }
    }

    func start() {
        assertMainThread()
        // Ignore a start while a previous stop is still finalizing, and don't start on
        // top of an in-flight recording.
        guard state == .idle, !isStopping else { return }

        guard isSupported else {
            presentError?("Recording unavailable",
                          "Recording requires macOS 14.2 or later.")
            return
        }
        if isDeliveryAvailable?() == false {
            presentError?("No page open",
                          "Open a gitmost page first, then start recording.")
            return
        }

        guard #available(macOS 14.2, *) else { return } // unreachable given isSupported
        let recorder = AudioRecorder()
        do {
            try recorder.start()
        } catch {
            self.recorder = nil
            presentError?("Could not start recording", error.localizedDescription)
            return
        }
        self.recorder = recorder
        state = .recording
        startDate = Date()
        accumulatedPaused = 0
        pauseDate = nil
        broadcast()
    }

    func stop() {
        assertMainThread()
        guard state == .recording || state == .paused else { return }
        guard #available(macOS 14.2, *), let recorder = recorder as? AudioRecorder else {
            // No live recorder to finalize; just reset.
            resetTiming()
            state = .idle
            self.recorder = nil
            broadcast()
            return
        }

        // Flip state and clear the recorder reference SYNCHRONOUSLY before calling stop(),
        // mirroring the old isStopping discipline: a second toggle() arriving before the
        // completion runs can neither re-enter stop() (state is already .idle) nor start a
        // new recording (isStopping blocks it).
        //
        // INVARIANT: AudioRecorder.stop's completion MUST run exactly once on every path,
        // or isStopping stays true and permanently disables recording.
        isStopping = true
        state = .idle
        self.recorder = nil
        resetTiming()
        broadcast()

        recorder.stop { [weak self] result in
            // AudioRecorder calls completion synchronously on the calling thread; hop to
            // the main thread to touch UI / deliver the file safely.
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isStopping = false
                switch result {
                case .success(let url):
                    self.deliverFile?(url)
                case .failure(let error):
                    self.presentError?("Recording failed", error.localizedDescription)
                }
            }
        }
    }

    // No-op unless recording.
    func pause() {
        assertMainThread()
        guard state == .recording else { return }
        if #available(macOS 14.2, *), let recorder = recorder as? AudioRecorder {
            recorder.pause()
        }
        pauseDate = Date()
        state = .paused
        broadcast()
    }

    // No-op unless paused.
    func resume() {
        assertMainThread()
        guard state == .paused else { return }
        if #available(macOS 14.2, *), let recorder = recorder as? AudioRecorder {
            recorder.resume()
        }
        // Fold the just-finished pause span into the accumulator so elapsedTime excludes it.
        if let pauseDate = pauseDate {
            accumulatedPaused += Date().timeIntervalSince(pauseDate)
        }
        pauseDate = nil
        state = .recording
        broadcast()
    }

    // MARK: - Helpers

    private func resetTiming() {
        startDate = nil
        accumulatedPaused = 0
        pauseDate = nil
    }

    private func broadcast() {
        NotificationCenter.default.post(name: .recordingStateDidChange, object: self)
    }

    private func assertMainThread() {
        assert(Thread.isMainThread, "RecordingController must be used on the main thread")
    }
}
