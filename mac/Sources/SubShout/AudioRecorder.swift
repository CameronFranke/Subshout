import AVFoundation
import Foundation
import OSLog

/// Captures from the default input device and produces a mono float32
/// 16 kHz PCM `Data` blob on stop.
///
/// The hardware format is whatever the system gave us (typically stereo @
/// 44.1 or 48 kHz).  We let `AVAudioConverter` resample/downmix on the
/// audio thread; the converted samples are
///
///   * appended to a contiguous PCM buffer (drained on stop, sent to the
///     daemon for transcription), and
///   * pushed through a `FrequencyAnalyzer` whose output drives the pill's
///     spectrum visualisation.
///
/// Spectrum levels arrive on the audio thread via `bandsHandler` —
/// callers MUST hop to the main queue before touching UI.
///
/// ### Lifecycle: one engine per recording
///
/// `AVAudioEngine.stop()` halts the render thread but does **not** close
/// the input device.  The CoreAudio HAL stays open — orange "mic in use"
/// dot stays lit, audio interfaces with input monitoring keep routing the
/// mic into your headphones, other apps see the device as busy.  The only
/// reliable way to release the device is to drop every reference to the
/// engine and let ARC tear it down.
///
/// So: `engine`, `converter`, and `targetFormat` are all optionals that
/// exist together for the duration of a recording and are nil between
/// recordings.  `isRunning` is computed from `engine != nil` — there is
/// exactly one source of truth for "is the mic open right now".  `start()`
/// either fully builds the graph or rolls back to a pristine state on
/// throw.  `stopAndDrain()` is unconditional teardown.
///
/// ### Latency story
///
/// Two knobs collude to give us ~5 ms callbacks and a snappy visualizer:
///
///   1. **Hardware buffer**: `AudioDeviceConfig` writes
///      `kAudioDevicePropertyBufferFrameSize` to 256 frames on the default
///      input device before the engine starts, and restores the prior
///      value on stop.  This is the same dial pro audio apps use.
///   2. **Tap bufferSize**: we pass that same 256 to `installTap` so the
///      AVAudioEngine convenience layer doesn't accumulate behind the
///      scenes (which is what its documented 100 ms minimum is about).
///
/// If `AudioDeviceConfig` fails to set the hardware buffer (driver said
/// no, device disappeared, etc.) we fall through to whatever size it
///  returned.  Transcription is unaffected — only the visualizer's
/// responsiveness depends on this.
final class AudioRecorder {
    private let log = Logger(subsystem: "com.cameronfranke.SubShout", category: "AudioRecorder")

    static let targetSampleRate: Double = 16_000

    /// Tap buffer target. Keep this conservative: some external / virtual input
    /// devices accept tiny HAL buffer sizes but then never deliver tap buffers
    /// to AVAudioEngine. 1024 frames is still low-latency enough for dictation
    /// and much more reliable across devices.
    private static let preferredTapFrames: AVAudioFrameCount = 1024

    // The recording graph.  All three are non-nil during a recording and
    // nil otherwise.  See "Lifecycle" in the type doc.
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var sinkNode: AVAudioSinkNode?

    private let lock = NSLock()  // protects `pcmBuffer`
    private var pcmBuffer: [Float] = []
    private let analyzer = FrequencyAnalyzer()
    private let deviceConfig = AudioDeviceConfig()
    private var inputBufferCount = 0
    private var convertedSampleCount = 0
    private var peakLevel: Float = 0
    private var zeroOutputReports = 0

    /// True iff a recording is in progress.  Single source of truth: an
    /// engine exists ⇔ the mic is open.
    var isRunning: Bool { engine != nil }

    /// Called on an arbitrary audio thread with the latest spectrum.
    /// Length = `FrequencyAnalyzer.bandCount` (currently 21).  Each element
    /// is in `[0, 1]`.
    var bandsHandler: (([Float]) -> Void)?

    deinit {
        // Belt-and-suspenders: if the recorder is released mid-recording
        // (controller torn down, app quitting), make sure we don't leak
        // an open mic into the next process to want it.
        if engine != nil {
            _ = stopAndDrain()
        }
    }

    // MARK: - Permission

    static func ensureMicPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default: return false
        }
    }

    // MARK: - Start / Stop

    func start() throws {
        guard engine == nil else { return }

        // 1) Use a conservative tap buffer. Earlier builds forced the HAL input
        //    device to 256 frames for visualizer latency, but some devices then
        //    opened successfully without ever delivering AVAudioEngine tap
        //    buffers. Dictation correctness beats sub-10ms visual latency.
        let tapFrames = Self.preferredTapFrames

        // 2) Build a fresh engine and the rest of the graph.  Keep
        //    everything in locals until we know we can start — that way a
        //    throw leaves the AudioRecorder pristine (engine == nil).
        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let newSink = AVAudioSinkNode { _, _, _ in noErr }
        guard inputFormat.sampleRate > 0 else {
            deviceConfig.restore()
            throw SubShoutError.audioEngineFailed("input format has zero sample rate (no input device?)")
        }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            deviceConfig.restore()
            throw SubShoutError.audioEngineFailed("could not build target AVAudioFormat")
        }
        guard let newConverter = AVAudioConverter(from: inputFormat, to: target) else {
            deviceConfig.restore()
            throw SubShoutError.audioEngineFailed("could not build AVAudioConverter for \(inputFormat) → \(target)")
        }

        lock.lock()
        pcmBuffer.removeAll(keepingCapacity: true)
        lock.unlock()
        inputBufferCount = 0
        convertedSampleCount = 0
        peakLevel = 0
        zeroOutputReports = 0

        analyzer.reset()
        analyzer.output = { [weak self] bands in
            self?.bandsHandler?(bands)
        }

        log.info(
            "starting capture: \(inputFormat.sampleRate, privacy: .public) Hz, \(inputFormat.channelCount) ch, tapBuffer=\(tapFrames) frames"
        )

        // 3) Commit the graph to `self` *before* installing the tap.  The
        //    tap closure reads `self.converter` / `self.targetFormat`; if
        //    a buffer arrived between installTap and assignment we'd drop
        //    it.  Buffers don't actually flow until engine.start() below,
        //    but this ordering makes that not matter.
        self.engine = newEngine
        self.converter = newConverter
        self.targetFormat = target
        self.sinkNode = newSink

        // 4) Build a real pull graph and install the input tap. A tap-only input
        //    graph can start successfully but never deliver callbacks on some
        //    devices (notably Bluetooth/aggregate inputs). Routing input into a
        //    no-op sink node forces AVAudioEngine to render the input stream
        //    without sending microphone audio to the user's speakers.
        newEngine.attach(newSink)
        newEngine.connect(input, to: newSink, format: inputFormat)
        input.installTap(onBus: 0, bufferSize: tapFrames, format: inputFormat) { [weak self] inputBuf, _ in
            self?.process(inputBuf)
        }

        newEngine.prepare()
        do {
            try newEngine.start()
        } catch {
            // Partial-build rollback.  Same shape as stopAndDrain's
            // teardown but without the buffer drain (there can't be any
            // samples — the engine never started).
            input.removeTap(onBus: 0)
            self.engine = nil
            self.converter = nil
            self.targetFormat = nil
            self.sinkNode = nil
            deviceConfig.restore()
            throw SubShoutError.audioEngineFailed("engine.start() failed: \(error.localizedDescription)")
        }
    }

    /// Stop capture and return the accumulated PCM as little-endian float32
    /// bytes (the wire format the daemon expects).
    ///
    /// Unconditional teardown: removeTap → stop → drop the engine.  After
    /// this returns, `isRunning == false` and the CoreAudio input device
    /// has been released.
    @discardableResult
    func stopAndDrain() -> Data {
        guard let engine = self.engine else { return Data() }

        // Order matters.  removeTap first so no further buffers can be
        // delivered to a stale `process()` callback; engine.stop() to
        // halt the render thread; then drop our references so ARC tears
        // the engine down and CoreAudio releases the HAL device.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        self.converter = nil
        self.targetFormat = nil
        self.sinkNode = nil

        // Be a good citizen: put the device back the way we found it.
        deviceConfig.restore()

        lock.lock()
        let copy = pcmBuffer
        pcmBuffer.removeAll(keepingCapacity: false)
        lock.unlock()

        log.info(
            "stopped capture: inputBuffers=\(self.inputBufferCount, privacy: .public) samples=\(copy.count, privacy: .public) seconds=\(Double(copy.count) / Self.targetSampleRate, privacy: .public) peak=\(self.peakLevel, privacy: .public)"
        )

        // Float32 is already 4-byte little-endian on Apple silicon — no swap.
        return copy.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - Audio thread

    private func process(_ inputBuf: AVAudioPCMBuffer) {
        // converter / targetFormat may be nil if a buffer was already in
        // flight when stopAndDrain ran.  In practice removeTap quiesces
        // before returning, but the early-return is free insurance.
        guard let converter = converter, let target = targetFormat else { return }
        inputBufferCount += 1
        if inputBufferCount == 1 {
            log.info(
                "first input buffer: frames=\(inputBuf.frameLength, privacy: .public) sampleRate=\(inputBuf.format.sampleRate, privacy: .public) channels=\(inputBuf.format.channelCount, privacy: .public)"
            )
        }

        let ratio = target.sampleRate / inputBuf.format.sampleRate
        // Keep this comfortably larger than one tiny hardware callback. Some
        // sample-rate converters emit buffered output in bursts rather than one
        // perfectly proportional chunk per input callback.
        let outCap = max(
            AVAudioFrameCount(1024),
            AVAudioFrameCount(Double(inputBuf.frameLength) * ratio) + 128
        )
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else {
            return
        }

        var consumed = false
        var emittedThisInput = 0
        while true {
            var error: NSError?
            outBuf.frameLength = 0
            let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return inputBuf
            }
            if let e = error {
                log.error("converter error: \(e.localizedDescription, privacy: .public)")
                return
            }
            if status == .error { return }

            let n = Int(outBuf.frameLength)
            if n > 0, let channels = outBuf.floatChannelData {
                let samples = channels[0]
                analyzer.push(samples, count: n)

                lock.lock()
                pcmBuffer.reserveCapacity(pcmBuffer.count + n)
                for i in 0..<n {
                    let sample = samples[i]
                    pcmBuffer.append(sample)
                    peakLevel = max(peakLevel, abs(sample))
                }
                lock.unlock()

                emittedThisInput += n
                convertedSampleCount += n
            }

            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream:
                break
            case .error:
                return
            @unknown default:
                break
            }
            break
        }

        if emittedThisInput == 0 && zeroOutputReports < 3 {
            zeroOutputReports += 1
            log.warning(
                "converter emitted 0 frames for input buffer \(self.inputBufferCount, privacy: .public); totalConverted=\(self.convertedSampleCount, privacy: .public)"
            )
        }
    }
}
