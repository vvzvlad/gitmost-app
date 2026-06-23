import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import os
import DocmostCore

// Captures system audio output + the default microphone into a single AAC .m4a file
// using the macOS 14.2+ Core Audio process-tap API.
//
// High-level approach (documented path; reference: github.com/insidegui/AudioCap):
//   1. Create a global process tap of the system output.
//   2. Read the tap's stream format (sample rate, channel count) — authoritative.
//   3. Find the default input device (microphone) and its UID.
//   4. Build a private aggregate device that bundles BOTH the tap (system audio) AND
//      the microphone as a sub-device, so ONE IO proc delivers all channels.
//   5. In the IO proc, mix the tap channels + mic channels down to stereo Float32 and
//      append to an AVAudioFile (AAC encoder).
//   6. Tear everything down on stop and finalize the file.
//
// IMPORTANT (runtime validation needed): the exact channel layout inside the IO proc's
// input AudioBufferList — i.e. which buffers/channels are the system tap vs. the mic,
// and whether they arrive interleaved or as separate buffers — depends on how Core
// Audio lays out the aggregate. The mixing logic is isolated in `mixToStereo(...)` and
// heavily commented so it is easy to adjust once observed on a real 14.2+ Mac.
@available(macOS 14.2, *)
final class AudioRecorder {

    enum State {
        case idle
        case recording
    }

    enum RecordingError: Error, LocalizedError {
        case unsupportedOS
        case tapCreationFailed(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case noInputDevice
        case ioProcSetupFailed(OSStatus)
        case deviceStartFailed(OSStatus)
        case fileWriteFailed

        // Human-readable messages so MainViewController's alerts (which surface
        // `error.localizedDescription`) explain what went wrong and how to fix it.
        var errorDescription: String? {
            // Hint shown for failures that are most often a missing permission.
            let permissionHint = "Grant system-audio and microphone recording permission in "
                + "System Settings → Privacy & Security, then try again."
            switch self {
            case .unsupportedOS:
                return "Recording requires macOS 14.2 or later."
            case .tapCreationFailed(let status):
                return "Could not start system-audio capture (status \(status)). \(permissionHint)"
            case .aggregateCreationFailed(let status):
                return "Could not create the audio recording device (status \(status)). \(permissionHint)"
            case .noInputDevice:
                return "No microphone (audio input device) is available. Connect or enable a "
                    + "microphone and try again."
            case .ioProcSetupFailed(let status):
                return "Could not set up the audio capture callback (status \(status))."
            case .deviceStartFailed(let status):
                return "Could not start the audio recording device (status \(status))."
            case .fileWriteFailed:
                return "Writing the recording file failed."
            }
        }
    }

    private(set) var state: State = .idle

    // Core Audio handles created during start(), released during stop().
    private var tapID: AUAudioObjectID = AUAudioObjectID(kAudioObjectUnknown)
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    // Output file + the format we write into it (stereo, tap sample rate).
    private var outputFile: AVAudioFile?
    private var outputFormat: AVAudioFormat?
    private var outputURL: URL?

    // Serial queue for the IO proc callbacks.
    private let ioQueue = DispatchQueue(label: "xyz.vvzvlad.gitmost.audio-io")

    // Serializes ALL Core Audio graph mutations (initial build, device-switch rebuild,
    // teardown) so a rebuild triggered by a default-device change can never interleave
    // with stop() or another rebuild. The device-change listener block dispatches here.
    private let controlQueue = DispatchQueue(label: "xyz.vvzvlad.gitmost.audio-control")

    // Set inside the IO proc when an AVAudioFile write throws; surfaced on stop().
    private var writeFailed = false

    // Paused flag. IO-proc-shared state: read in handleInput on `ioQueue`, written via
    // ioQueue.sync from pause()/resume(). When true the IO proc keeps the tap/aggregate
    // running but skips appending to the file.
    private var isPaused = false

    // Most-recent mixed-buffer peak in 0...1, written by the IO proc and read from the
    // main thread. Guarded by `levelLock` (os_unfair_lock) so the read is data-race free.
    private var level: Float = 0
    private var levelLock = os_unfair_lock_s()

    // Device-change support. We keep the original tap stream format so a rebuild against a
    // new default device can detect a sample-rate mismatch (which would corrupt the file).
    // The two listener blocks are retained so we can remove them on teardown.
    private var originalTapSampleRate: Double = 0
    private var inputListenerBlock: AudioObjectPropertyListenerBlock?
    private var outputListenerBlock: AudioObjectPropertyListenerBlock?
    // True once stop()/teardown has begun, so a device-change listener that fires during or
    // after teardown becomes a no-op instead of rebuilding a torn-down graph. Touched only
    // on `controlQueue`.
    private var isTearingDown = false
    // Set inside a rebuild when the new device's format is incompatible with the open file;
    // surfaced on stop() like writeFailed. Touched on `controlQueue` / under ioQueue.sync.
    private var rebuildFailed = false

    // MARK: - Public API

    // Begins capture to a temp .m4a file. Throws on any Core Audio / file failure and
    // leaves no half-initialized state behind.
    func start() throws {
        guard state == .idle else { return }

        // Reset state invariants up front, while no IO proc is running (single-threaded
        // here): a previous recording or a failed start() may have left these set.
        writeFailed = false
        rebuildFailed = false
        isPaused = false
        isTearingDown = false
        outputURL = nil
        setLevel(0)

        do {
            try createTap()
            let format = try readTapFormat()
            // Remember the tap's sample rate; a device-switch rebuild that yields a
            // different rate would not match the open file and must be rejected.
            originalTapSampleRate = format.mSampleRate
            let micUID = try defaultInputDeviceUID()
            try createAggregateDevice(tapUID: try tapUID(), micUID: micUID)
            try openOutputFile(sampleRate: format.mSampleRate)
            try installIOProc()
            try startDevice()
        } catch {
            // Roll back anything that succeeded so a retry starts clean.
            // teardownCoreAudio() destroys any installed IO proc first (synchronously
            // guaranteeing no further callbacks); close the file inside ioQueue.sync to
            // keep IO-proc-shared state (`outputFile`) touched only on `ioQueue`.
            teardownCoreAudio()
            ioQueue.sync { closeOutputFile() }
            throw error
        }

        state = .recording

        // Begin observing default-device changes only after the graph is up and the file
        // is open, so a listener firing mid-build can never race the initial setup.
        installDeviceChangeListeners()
    }

    // Stops capture, finalizes the file and returns its URL (or an error).
    func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        guard state == .recording else {
            completion(.failure(RecordingError.fileWriteFailed))
            return
        }
        state = .idle

        // Remove the default-device listeners first so no new rebuild can be scheduled
        // onto controlQueue from here on. (Already-queued rebuilds are fenced by the
        // controlQueue.sync teardown below plus the isTearingDown guard inside rebuild.)
        removeDeviceChangeListeners()

        var didWriteFail = false
        var didRebuildFail = false

        // Run the whole teardown on controlQueue so it is serialized against any in-flight
        // device-switch rebuild: a rebuild either fully completes before this block or is
        // turned into a no-op by `isTearingDown` once this block sets it.
        controlQueue.sync {
            isTearingDown = true

            // Teardown order is load-bearing for thread safety (the IO proc runs on `ioQueue`):
            //   1. Stop the device so no new IO callback is scheduled.
            //   2. Destroy the IO proc ID. AudioDeviceDestroyIOProcID synchronously guarantees
            //      the block will not run again — do this BEFORE touching IO-proc-shared state
            //      (`writeFailed`, `outputFile`). Clear the stored ID so teardownCoreAudio()
            //      does not destroy it a second time.
            //   3. Read `writeFailed`/`rebuildFailed` and close the file INSIDE ioQueue.sync
            //      so this thread observes (happens-before) every write the IO proc made on
            //      that same queue.
            //   4. Destroy the aggregate device and the tap (the rest of teardownCoreAudio()).
            if let procID = ioProcID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
                ioProcID = nil
            }

            ioQueue.sync {
                didWriteFail = writeFailed
                didRebuildFail = rebuildFailed
                closeOutputFile()
            }

            teardownCoreAudio()
        }

        if didWriteFail || didRebuildFail {
            completion(.failure(RecordingError.fileWriteFailed))
            return
        }
        guard let url = outputURL else {
            completion(.failure(RecordingError.fileWriteFailed))
            return
        }
        completion(.success(url))
    }

    // Pauses writing without tearing down Core Audio. The tap/aggregate keep running; the
    // IO proc simply stops appending while paused. Safe to call when already paused or
    // not recording (no-op at the file level).
    func pause() {
        // Write isPaused under ioQueue.sync so handleInput observes it on its own queue.
        ioQueue.sync { isPaused = true }
    }

    // Resumes appending after a pause.
    func resume() {
        ioQueue.sync { isPaused = false }
    }

    // Thread-safe snapshot of the most-recent mixed-buffer peak (0...1). Readable from the
    // main thread. Returns the lock-protected level snapshot without touching `ioQueue`, so
    // the UI level meter never blocks the main thread on the realtime audio IO queue. The
    // "0 while paused" behavior is provided elsewhere: RecordingController.audioLevel returns
    // 0 when not recording, and handleInput already calls setLevel(0) while paused.
    var currentLevel: Float {
        return readLevel()
    }

    // MARK: - Audio level metering

    // Reads the current level under the lock.
    private func readLevel() -> Float {
        os_unfair_lock_lock(&levelLock)
        let value = level
        os_unfair_lock_unlock(&levelLock)
        return value
    }

    // Stores a level value under the lock.
    private func setLevel(_ value: Float) {
        os_unfair_lock_lock(&levelLock)
        level = value
        os_unfair_lock_unlock(&levelLock)
    }

    // Computes the peak absolute sample of the mixed stereo buffer and stores it with a
    // light decay so the meter falls smoothly instead of snapping to 0 between blocks.
    private func updateLevel(from pcm: AVAudioPCMBuffer) {
        guard let channelData = pcm.floatChannelData else { return }
        let frames = Int(pcm.frameLength)
        let channels = Int(pcm.format.channelCount)
        var peak: Float = 0
        for ch in 0..<channels {
            let samples = channelData[ch]
            for frame in 0..<frames {
                let magnitude = abs(samples[frame])
                if magnitude > peak { peak = magnitude }
            }
        }
        peak = min(1, peak)

        // Smooth: rise instantly to a new peak, decay gently otherwise.
        let previous = readLevel()
        let smoothed = peak >= previous ? peak : previous * 0.85 + peak * 0.15
        setLevel(smoothed)
    }

    // MARK: - Default-device change handling (RUNTIME VALIDATION REQUIRED)

    // Registers property listeners on the system object for default-input and
    // default-output device changes. When the user switches their mic or speakers while
    // recording, we rebuild the Core Audio graph against the new device(s) while KEEPING
    // the same open AVAudioFile so the recording continues into one file.
    //
    // The listener blocks dispatch onto `controlQueue`, the single serialization point for
    // all graph mutations, so a rebuild can never interleave with stop() or another
    // rebuild.
    private func installDeviceChangeListeners() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        // Capture self weakly: the recorder may be deallocated while a listener is queued.
        let inputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.controlQueue.async { self?.rebuildGraphForDeviceChange() }
        }
        let outputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.controlQueue.async { self?.rebuildGraphForDeviceChange() }
        }
        self.inputListenerBlock = inputBlock
        self.outputListenerBlock = outputBlock

        // Deliver listener callbacks on controlQueue too; we still hop via async inside the
        // block to keep the public dispatch path uniform with stop()'s serialization.
        AudioObjectAddPropertyListenerBlock(systemObject, &inputAddress, controlQueue, inputBlock)
        AudioObjectAddPropertyListenerBlock(systemObject, &outputAddress, controlQueue, outputBlock)
    }

    // Removes the default-device listeners. Called from stop()/teardown so no rebuild is
    // scheduled after teardown begins.
    private func removeDeviceChangeListeners() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        if let inputBlock = inputListenerBlock {
            AudioObjectRemovePropertyListenerBlock(systemObject, &inputAddress, controlQueue, inputBlock)
            inputListenerBlock = nil
        }
        if let outputBlock = outputListenerBlock {
            AudioObjectRemovePropertyListenerBlock(systemObject, &outputAddress, controlQueue, outputBlock)
            outputListenerBlock = nil
        }
    }

    // Rebuilds the tap + aggregate + IO proc against the now-current default devices while
    // keeping the SAME open output file so the recording continues uninterrupted. Runs on
    // controlQueue (the listener dispatched here), so it is serialized against stop() and
    // any other rebuild.
    //
    // RUNTIME VALIDATION REQUIRED: device hot-swap is the highest-risk path. The exact
    // failure modes (e.g. brief callback gaps during the swap, whether the new tap reports
    // the same sample rate) need observation on real 14.2+ hardware.
    private func rebuildGraphForDeviceChange() {
        // A listener may fire during/after teardown; this guard makes that a no-op so we
        // never rebuild a graph that stop() is dismantling.
        guard !isTearingDown else { return }
        // Nothing to rebuild if a previous rebuild already failed the recording.
        guard !rebuildFailed else { return }

        // 1. Stop + destroy the current IO proc. AudioDeviceDestroyIOProcID synchronously
        //    fences any in-flight callback, so after this no handleInput runs.
        if let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
        }
        // 2. Destroy the aggregate device and the tap (but NOT the output file).
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AUAudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AUAudioObjectID(kAudioObjectUnknown)
        }

        // 3. Recreate tap/aggregate/ioproc/startDevice via the EXISTING helpers against the
        //    now-current default devices. On any failure, fail the recording cleanly:
        //    set rebuildFailed (handleInput will stop writing; stop() surfaces the error
        //    via its completion path) rather than silently producing a corrupt file.
        do {
            try createTap()
            let format = try readTapFormat()
            // The open AVAudioFile was created at originalTapSampleRate. If the new device's
            // tap reports a different rate, writing its buffers into the existing file would
            // corrupt it. We cannot resample inside the IO proc cheaply for v1, so reject
            // the rebuild and surface an error instead of writing mismatched audio.
            //
            // LIMITATION (v1): switching to a device whose system tap runs at a different
            // sample rate stops the recording. A best-effort resample is left for a later
            // iteration. This is intentionally fail-closed: no corrupt file is produced.
            if abs(format.mSampleRate - originalTapSampleRate) > 0.5 {
                rebuildFailed = true
                return
            }
            let micUID = try defaultInputDeviceUID()
            try createAggregateDevice(tapUID: try tapUID(), micUID: micUID)
            try installIOProc()
            try startDevice()
        } catch {
            // Could not rebuild against the new device: fail the recording cleanly.
            rebuildFailed = true
        }
    }

    // MARK: - Tap

    private func createTap() throws {
        // Global tap of system output, excluding no processes (capture everything).
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "gitmost system tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AUAudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != AUAudioObjectID(kAudioObjectUnknown) else {
            throw RecordingError.tapCreationFailed(status)
        }
        tapID = newTapID
    }

    // The tap's UUID string, used to reference it from the aggregate's tap list.
    private func tapUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size = UInt32(MemoryLayout<CFString>.size)
        var uid: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { throw RecordingError.tapCreationFailed(status) }
        return uid as String
    }

    // Reads the tap's stream format (sample rate + channel count). This rate is
    // authoritative for the output file so we avoid resampling. The "48 kHz" target is
    // only a preference; if the tap reports 44.1 kHz we use that (AAC supports both).
    private func readTapFormat() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mSampleRate > 0 else {
            throw RecordingError.tapCreationFailed(status)
        }
        return asbd
    }

    // MARK: - Microphone (default input device)

    private func defaultInputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            throw RecordingError.noInputDevice
        }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uid: CFString = "" as CFString
        let uidStatus = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, ptr)
        }
        guard uidStatus == noErr else { throw RecordingError.noInputDevice }
        return uid as String
    }

    // MARK: - Aggregate device

    private func createAggregateDevice(tapUID: String, micUID: String) throws {
        let aggregateUID = UUID().uuidString

        // One IO proc over this aggregate delivers system-tap channels AND the mic.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "gitmost recorder",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: false,
            kAudioAggregateDeviceMainSubDeviceKey as String: micUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: micUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: true
                ]
            ]
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary,
                                                        &newAggregateID)
        guard status == noErr, newAggregateID != AudioObjectID(kAudioObjectUnknown) else {
            throw RecordingError.aggregateCreationFailed(status)
        }
        aggregateID = newAggregateID
    }

    // MARK: - Output file

    private func openOutputFile(sampleRate: Double) throws {
        let name = RecordingSupport.fileName(for: Date())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)

        // Encode AAC m4a, stereo, at the tap's sample rate to avoid resampling.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000
        ]

        do {
            let file = try AVAudioFile(forWriting: url,
                                       settings: settings,
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            outputFile = file
            // Use the format AVAudioFile actually processes writes in (non-interleaved
            // stereo Float32 here) so write(from:) can never throw on a format mismatch.
            // Safe to set on this (caller) thread: no IO callback runs until startDevice().
            outputFormat = file.processingFormat
            outputURL = url
        } catch {
            throw RecordingError.fileWriteFailed
        }
    }

    private func closeOutputFile() {
        // AVAudioFile finalizes (writes the m4a moov atom) when it is deallocated.
        outputFile = nil
        // Clear the cached write format too; it is meaningless without an open file.
        // Safe: closeOutputFile() only runs before the IO proc starts or inside
        // ioQueue.sync, so this stays race-free with respect to handleInput.
        outputFormat = nil
    }

    // MARK: - IO proc

    private func installIOProc() throws {
        var newProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID, aggregateID, ioQueue) { [weak self] _, inInputData, _, _, _ in
                self?.handleInput(inInputData)
            }
        guard status == noErr, let procID = newProcID else {
            throw RecordingError.ioProcSetupFailed(status)
        }
        ioProcID = procID
    }

    private func startDevice() throws {
        guard let ioProcID else { throw RecordingError.ioProcSetupFailed(noErr) }
        let status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw RecordingError.deviceStartFailed(status) }
    }

    // Called on `ioQueue` (a Core Audio dispatch thread) for every input block. Mixes
    // the incoming buffers down to stereo and appends to the output file.
    private func handleInput(_ inInputData: UnsafePointer<AudioBufferList>) {
        guard !writeFailed, !rebuildFailed,
              let outputFile = outputFile,
              let outputFormat = outputFormat else { return }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inInputData))

        guard let pcmBuffer = mixToStereo(bufferList, format: outputFormat) else { return }

        // Update the metering snapshot from every block (even while paused we report 0 via
        // the explicit reset below) so the UI level meter tracks live input.
        updateLevel(from: pcmBuffer)

        // When paused, keep the tap/aggregate running but skip appending to the file; this
        // (read on ioQueue / written under ioQueue.sync) keeps a clean, gap-free file that
        // simply omits the paused span.
        if isPaused {
            setLevel(0)
            return
        }

        do {
            // Writing from the IO callback is acceptable for v1 (single producer; the
            // AAC encoder buffers internally). Kept simple and serialized on ioQueue.
            try outputFile.write(from: pcmBuffer)
        } catch {
            writeFailed = true
        }
    }

    // MARK: - Mixing (RUNTIME VALIDATION REQUIRED)

    // Mixes the aggregate's input buffers down to a non-interleaved stereo Float32
    // AVAudioPCMBuffer matching `format`.
    //
    // ASSUMED LAYOUT (validate on a real 14.2+ Mac and adjust here only):
    //   - The aggregate presents the system tap channels and the mic channels as a flat
    //     set of mono Float32 buffers in the AudioBufferList (one channel per buffer),
    //     all with the same frame count.
    //   - The FIRST up-to-two buffers are the system output (L, R); a subsequent buffer
    //     is the microphone (mono). This ordering follows tap-list-then-sub-device-list,
    //     but Core Audio is free to reorder — verify with the channel count.
    //
    // Mix rule: out.L = sysL + mic, out.R = sysR + mic, then clip to [-1, 1].
    private func mixToStereo(_ buffers: UnsafeMutableAudioBufferListPointer,
                             format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard buffers.count > 0 else { return nil }

        // All sub-buffers in an aggregate share the same frame count; derive it from the
        // first buffer assuming mono Float32 (4 bytes/sample). If a buffer is interleaved
        // stereo, mNumberChannels > 1 and we still treat data as Float32 samples below.
        let firstChannels = max(1, Int(buffers[0].mNumberChannels))
        let frameCount = Int(buffers[0].mDataByteSize) /
            (MemoryLayout<Float32>.size * firstChannels)
        guard frameCount > 0 else { return nil }

        guard let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcm.frameLength = AVAudioFrameCount(frameCount)

        guard let channelData = pcm.floatChannelData else { return nil }
        let outL = channelData[0]
        let outR = channelData[1]

        // Zero the output, then accumulate every input channel into the stereo bus.
        for frame in 0..<frameCount {
            outL[frame] = 0
            outR[frame] = 0
        }

        // Treat the input buffers positionally: index 0 -> left bus, index 1 -> right
        // bus, every further buffer (e.g. the mono mic) -> both buses. This sums system
        // stereo + mic mono into both output channels as specified.
        for (index, buffer) in buffers.enumerated() {
            guard let raw = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let samples = Int(buffer.mDataByteSize) /
                (MemoryLayout<Float32>.size * channels)
            let count = min(samples, frameCount)
            let ptr = raw.assumingMemoryBound(to: Float32.self)

            if channels >= 2 {
                // Interleaved stereo buffer: split L/R into the stereo bus directly.
                for frame in 0..<count {
                    outL[frame] += ptr[frame * channels]
                    outR[frame] += ptr[frame * channels + 1]
                }
            } else {
                // Mono buffer. Route by position: first -> L, second -> R, rest -> both.
                switch index {
                case 0:
                    for frame in 0..<count { outL[frame] += ptr[frame] }
                case 1:
                    for frame in 0..<count { outR[frame] += ptr[frame] }
                default:
                    for frame in 0..<count {
                        outL[frame] += ptr[frame]
                        outR[frame] += ptr[frame]
                    }
                }
            }
        }

        // Simple clipping protection so summed sources never exceed full scale.
        for frame in 0..<frameCount {
            outL[frame] = max(-1.0, min(1.0, outL[frame]))
            outR[frame] = max(-1.0, min(1.0, outR[frame]))
        }

        return pcm
    }

    // MARK: - Teardown

    // Releases Core Audio objects in the documented order. Safe to call partially —
    // each handle is checked and reset so start()'s rollback path can reuse it.
    //
    // NOTE: stop(completion:) destroys the IO proc itself (and clears `ioProcID`) before
    // calling this, so the IO proc is normally gone here. The block below only runs for
    // start()'s error-path rollback, where the proc may have been installed/started but
    // stop() was never reached. It must NOT re-stop/re-destroy a proc stop() already
    // tore down — the `ioProcID != nil` guard ensures that.
    private func teardownCoreAudio() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AUAudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AUAudioObjectID(kAudioObjectUnknown)
        }
    }
}
