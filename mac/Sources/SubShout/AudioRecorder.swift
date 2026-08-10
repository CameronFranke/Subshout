import AVFoundation
import CoreMedia
import Foundation
import OSLog

/// Captures from the default input device and produces mono little-endian
/// float32 16 kHz PCM on stop.
///
/// Earlier versions used `AVAudioEngine.inputNode.installTap`. That worked for
/// the built-in mic but some Bluetooth aggregate inputs could start the engine
/// successfully while delivering zero tap buffers. `AVCaptureSession` is the
/// more direct macOS capture stack and handles the default input route,
/// including Bluetooth headsets, more reliably.
final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let log = Logger(subsystem: "com.cameronfranke.SubShout", category: "AudioRecorder")

    static let targetSampleRate: Double = 16_000
    static let maximumRecordingSeconds: Double = 300
    private static let maximumSampleCount = Int(
        targetSampleRate * maximumRecordingSeconds
    )

    private var session: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let captureQueue = DispatchQueue(label: "com.cameronfranke.SubShout.AudioCapture")

    private let lock = NSLock()
    private var pcmBuffer: [Float] = []
    private let analyzer = FrequencyAnalyzer()

    private var inputBufferCount = 0
    private var sampleCount = 0
    private var peakLevel: Float = 0
    private var loggedFirstBuffer = false
    private var didReachRecordingLimit = false

    /// True iff a recording is in progress.
    var isRunning: Bool { session?.isRunning == true }

    /// Called on an arbitrary audio thread with the latest spectrum.
    /// Length = `FrequencyAnalyzer.bandCount` (currently 21). Each element is
    /// in `[0, 1]`.
    var bandsHandler: (([Float]) -> Void)?

    /// Called once when a take reaches the hard PCM limit. The receiver must
    /// stop capture; the audio callback itself must not block on session I/O.
    var recordingLimitHandler: (() -> Void)?

    deinit {
        if session != nil {
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
        guard session == nil else { return }

        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw SubShoutError.audioEngineFailed("no default audio input device")
        }

        let newSession = AVCaptureSession()
        let newOutput = AVCaptureAudioDataOutput()

        // Ask AVFoundation to hand us exactly the daemon's wire format. This
        // keeps the capture callback simple and avoids AVAudioEngine/BT aggregate
        // edge cases.
        newOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        newSession.beginConfiguration()
        defer { newSession.commitConfiguration() }

        let input = try AVCaptureDeviceInput(device: device)
        guard newSession.canAddInput(input) else {
            throw SubShoutError.audioEngineFailed("could not add input device: \(device.localizedName)")
        }
        newSession.addInput(input)

        guard newSession.canAddOutput(newOutput) else {
            throw SubShoutError.audioEngineFailed("could not add AVCaptureAudioDataOutput")
        }
        newSession.addOutput(newOutput)
        newOutput.setSampleBufferDelegate(self, queue: captureQueue)

        lock.lock()
        pcmBuffer.removeAll(keepingCapacity: true)
        inputBufferCount = 0
        sampleCount = 0
        peakLevel = 0
        loggedFirstBuffer = false
        didReachRecordingLimit = false
        lock.unlock()

        analyzer.reset()
        analyzer.output = { [weak self] bands in
            self?.bandsHandler?(bands)
        }

        self.session = newSession
        self.audioOutput = newOutput

        log.info("starting capture: device=\(device.localizedName, privacy: .public)")
        // `startRunning()` is synchronous and can block for seconds or wedge on
        // problematic Bluetooth aggregate devices. Never run it on the main
        // actor; start the session on the capture queue and let stop tear it
        // down from that same queue.
        captureQueue.async { [weak self, newSession] in
            newSession.startRunning()
            self?.log.info("capture session running=\(newSession.isRunning, privacy: .public)")
        }
    }

    /// Stop capture and return the accumulated PCM as little-endian float32
    /// bytes (the wire format the daemon expects).
    @discardableResult
    func stopAndDrain() -> Data {
        guard let session = self.session else { return Data() }

        audioOutput?.setSampleBufferDelegate(nil, queue: nil)
        self.audioOutput = nil
        self.session = nil

        // Stop on the same serial queue used to start the session. Do not block
        // the main actor here; Bluetooth devices can be slow to tear down.
        captureQueue.async { [weak self, session] in
            session.stopRunning()
            self?.log.info("capture session stopped")
        }

        lock.lock()
        let copy = pcmBuffer
        pcmBuffer.removeAll(keepingCapacity: false)
        let buffers = inputBufferCount
        let samples = sampleCount
        let peak = peakLevel
        lock.unlock()

        log.info(
            "stopped capture: inputBuffers=\(buffers, privacy: .public) samples=\(samples, privacy: .public) seconds=\(Double(samples) / Self.targetSampleRate, privacy: .public) peak=\(peak, privacy: .public)"
        )

        // Float32 is already 4-byte little-endian on Apple silicon — no swap.
        return copy.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        process(sampleBuffer)
    }

    // MARK: - Audio callback

    private func process(_ sampleBuffer: CMSampleBuffer) {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }

        if !loggedFirstBuffer {
            loggedFirstBuffer = true
            if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
               let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) {
                let asbd = streamDescription.pointee
                log.info(
                    "first input buffer: frames=\(frames, privacy: .public) sampleRate=\(asbd.mSampleRate, privacy: .public) channels=\(asbd.mChannelsPerFrame, privacy: .public) formatFlags=\(asbd.mFormatFlags, privacy: .public) bits=\(asbd.mBitsPerChannel, privacy: .public)"
                )
            } else {
                log.info("first input buffer: frames=\(frames, privacy: .public)")
            }
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            log.warning("sample buffer had no CMBlockBuffer")
            return
        }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let pointerStatus = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        let byteCount = min(totalLength, frames * MemoryLayout<Float>.stride)
        guard byteCount >= MemoryLayout<Float>.stride else { return }
        let floatCount = byteCount / MemoryLayout<Float>.stride

        if pointerStatus == kCMBlockBufferNoErr, let dataPointer {
            dataPointer.withMemoryRebound(to: Float.self, capacity: floatCount) { samples in
                append(samples: samples, count: floatCount)
            }
        } else {
            var data = Data(count: byteCount)
            let copyStatus = data.withUnsafeMutableBytes { rawBuffer in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: rawBuffer.baseAddress!
                )
            }
            guard copyStatus == kCMBlockBufferNoErr else {
                log.warning("could not copy CMBlockBuffer bytes: status=\(copyStatus, privacy: .public)")
                return
            }
            data.withUnsafeBytes { rawBuffer in
                rawBuffer.bindMemory(to: Float.self).withMemoryRebound(to: Float.self) { samples in
                    append(samples: samples.baseAddress!, count: floatCount)
                }
            }
        }
    }

    private func append(samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }

        lock.lock()
        let remaining = Self.maximumSampleCount - pcmBuffer.count
        let acceptedCount = max(0, min(count, remaining))
        let hitLimit = acceptedCount < count || pcmBuffer.count + acceptedCount == Self.maximumSampleCount
        let reachedLimit = hitLimit && !didReachRecordingLimit
        if reachedLimit {
            didReachRecordingLimit = true
        }
        if acceptedCount > 0 {
            inputBufferCount += 1
            sampleCount += acceptedCount
            pcmBuffer.reserveCapacity(pcmBuffer.count + acceptedCount)
            for i in 0..<acceptedCount {
                let sample = samples[i]
                pcmBuffer.append(sample)
                peakLevel = max(peakLevel, abs(sample))
            }
        }
        lock.unlock()

        if acceptedCount > 0 {
            analyzer.push(samples, count: acceptedCount)
        }
        if reachedLimit {
            recordingLimitHandler?()
        }
    }
}
