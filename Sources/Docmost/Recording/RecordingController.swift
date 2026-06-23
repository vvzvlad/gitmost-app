import Foundation
import DocmostCore

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

    // UI-facing session phase. It mirrors the recorder `State` for recording/paused but ALSO
    // models the post-stop delivery lifecycle (saving/done/failed) that the AFFiNE-style popup
    // shows. This is the single thing the panel observes. Main-thread only.
    enum Phase {
        case idle       // no session; the panel is hidden
        case recording  // capturing
        case paused     // capture paused (driven from the menu)
        case saving     // stop() issued; file is finalizing + being delivered
        case done       // delivered; brief confirmation before auto-dismiss
        case failed     // capture or delivery failed; brief notice before auto-dismiss
    }

    static let shared = RecordingController()
    private init() {}

    // Main-thread only. The single authoritative recording state (idle/recording/paused).
    private(set) var state: State = .idle

    // Main-thread only. The UI-facing session phase the panel/menu observe. Mirrors `state`
    // for recording/paused and adds the saving/done/failed delivery phases.
    private(set) var phase: Phase = .idle

    // Underlying recorder. Held as AnyObject because AudioRecorder is @available(macOS
    // 14.2, *) and the app targets 14.0; only ever created/cast behind an availability
    // guard. nil whenever state == .idle.
    private var recorder: AnyObject?

    // The recording feature on/off flag (UserDefaults-backed). Read on every canStart/start.
    private let featureStore = RecordingFeatureStore()

    // True from the moment stop() begins until its completion runs, mirroring the
    // re-entrancy discipline that previously lived in MainViewController: it prevents a
    // second toggle() from double-stopping a recording that is still finalizing.
    private var isStopping = false

    // Schedules the return to .idle after a terminal phase (done/failed). Always invalidated
    // and replaced before re-arming so it can never double-fire; cancelled when a new session
    // starts. Main-thread only.
    private var dismissTimer: Timer?

    // Wall-clock bookkeeping for elapsedTime. `startDate` is set when recording begins;
    // `accumulatedPaused` collects the total duration spent paused; `pauseDate` marks the
    // moment the current pause began (nil while not paused).
    private var startDate: Date?
    private var accumulatedPaused: TimeInterval = 0
    private var pauseDate: Date?

    // MARK: - App wiring (all invoked on the main thread)

    // Called on stop success with the finished .m4a file. The closure must invoke the supplied
    // completion exactly once (on the main thread) to report whether delivery succeeded, so the
    // controller can advance to .done or .failed.
    var deliverFile: ((URL, @escaping (Bool) -> Void) -> Void)?
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
        return isSupported && featureStore.isEnabled && (isDeliveryAvailable?() ?? false)
    }

    // MARK: - Public mutators (main thread only)

    // Driven by the UI phase: idle -> start, recording/paused -> stop, and saving/done/failed
    // -> no-op (a session is finalizing or auto-dismissing; nothing to toggle).
    func toggle() {
        assertMainThread()
        switch phase {
        case .idle:
            start()
        case .recording, .paused:
            stop()
        case .saving, .done, .failed:
            break
        }
    }

    func start() {
        assertMainThread()
        // Ignore a start while a previous stop is still finalizing, and don't start on
        // top of an in-flight recording.
        guard phase == .idle, !isStopping else { return }

        // A new session supersedes any pending auto-dismiss from a previous done/failed phase.
        cancelDismiss()

        guard featureStore.isEnabled else {
            presentError?("Recording disabled",
                          "Enable meeting recording in Settings first.")
            return
        }

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
        phase = .recording
        startDate = Date()
        accumulatedPaused = 0
        pauseDate = nil
        broadcast()
    }

    func stop() {
        assertMainThread()
        guard state == .recording || state == .paused else { return }
        guard #available(macOS 14.2, *), let recorder = recorder as? AudioRecorder else {
            // No live recorder to finalize; just reset to idle.
            resetTiming()
            state = .idle
            phase = .idle
            self.recorder = nil
            broadcast()
            return
        }

        // Flip the recorder state and clear the recorder reference SYNCHRONOUSLY before calling
        // stop(), mirroring the old isStopping discipline: a second toggle() arriving before the
        // completion runs can neither re-enter stop() (state is already .idle, phase is .saving)
        // nor start a new recording (isStopping blocks it). The UI phase moves to .saving — the
        // session is NOT over yet; the panel keeps showing a "Saving…" spinner.
        //
        // INVARIANT: AudioRecorder.stop's completion MUST run exactly once on every path,
        // or isStopping stays true and permanently disables recording.
        isStopping = true
        state = .idle
        phase = .saving
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
                    // Deliver the file and wait for delivery to report back. The session
                    // stays in .saving until then.
                    if let deliver = self.deliverFile {
                        // Guard against a double-callback from the delivery closure.
                        var didComplete = false
                        deliver(url) { [weak self] success in
                            self?.assertMainThread()
                            guard !didComplete else { return }
                            didComplete = true
                            self?.finishDelivery(success: success)
                        }
                    } else {
                        // No delivery wired: treat as failure so the session does not hang.
                        self.enterFailed()
                    }
                case .failure(let error):
                    self.presentError?("Recording failed", error.localizedDescription)
                    self.enterFailed()
                }
            }
        }
    }

    // Delivery completed: advance to the terminal phase and schedule the auto-dismiss back to
    // idle so the panel disappears (matching AFFiNE's session-scoped popup).
    private func finishDelivery(success: Bool) {
        assertMainThread()
        if success {
            enterDone()
        } else {
            enterFailed()
        }
    }

    // .done: brief "Recording saved" confirmation, then auto-dismiss after ~2s.
    private func enterDone() {
        assertMainThread()
        phase = .done
        broadcast()
        scheduleDismiss(after: 2.0)
    }

    // .failed: brief "Recording failed" notice, then auto-dismiss after ~4s.
    private func enterFailed() {
        assertMainThread()
        phase = .failed
        broadcast()
        scheduleDismiss(after: 4.0)
    }

    // Cancel any pending auto-dismiss and return to .idle immediately. Used by the panel's
    // "Dismiss" button so the user can close the popup without waiting for the timer.
    func dismiss() {
        assertMainThread()
        cancelDismiss()
        guard phase != .idle else { return }
        // Only terminal phases may be dismissed early; an active session must be stopped, not
        // dismissed, so guard against clobbering recording/paused/saving.
        guard phase == .done || phase == .failed else { return }
        phase = .idle
        broadcast()
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
        phase = .paused
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
        phase = .recording
        broadcast()
    }

    // MARK: - Helpers

    private func resetTiming() {
        startDate = nil
        accumulatedPaused = 0
        pauseDate = nil
    }

    // Arm the auto-dismiss timer that returns a terminal (done/failed) phase to idle. Always
    // invalidates any previous timer first so it can never double-fire.
    private func scheduleDismiss(after delay: TimeInterval) {
        assertMainThread()
        cancelDismiss()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.assertMainThread()
            self.dismissTimer = nil
            // Only clear a still-terminal phase; a new session started in the meantime must win.
            guard self.phase == .done || self.phase == .failed else { return }
            self.phase = .idle
            self.broadcast()
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }

    private func cancelDismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    private func broadcast() {
        NotificationCenter.default.post(name: .recordingStateDidChange, object: self)
    }

    private func assertMainThread() {
        assert(Thread.isMainThread, "RecordingController must be used on the main thread")
    }
}
