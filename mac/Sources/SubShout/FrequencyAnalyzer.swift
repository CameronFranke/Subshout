import Accelerate
import Foundation

/// Streaming FFT → log-spaced frequency bands, sized for the recording
/// pill.  Drop float32 samples in via `push`; you'll get a callback with
/// `bandCount` magnitudes (each in `[0, 1]`) every `hopSize` samples.
///
/// The pipeline:
///
///   1. Buffer samples into a `fftSize`-long ring.  Each time `hopSize`
///      new samples arrive (i.e. with `fftSize - hopSize` samples of
///      overlap from the previous window), run one analysis pass.
///   2. Apply a Hann window (kills spectral leakage from window edges).
///   3. Real-input FFT via `vDSP.FFT<DSPSplitComplex>`.
///   4. Magnitude per FFT bin.
///   5. Bin those magnitudes into `bandCount` log-spaced bands between
///      `lowFreq` and `highFreq`.
///   6. Slow AGC: divide by a running max-magnitude that decays over
///      ~5 seconds.  This gives the bars a consistent visible range
///      regardless of mic gain or how loud the user actually is, at the
///      cost of losing absolute-loudness information (which a 21-bar
///      meter was never going to convey anyway).
///   7. sqrt curve for visual punch — quiet sounds lift faster than a
///      linear mapping would give.
///   8. Per-band temporal EMA so bars don't flicker frame-to-frame.
///
/// Default config (tuned for "feels live"):
///
///   * fftSize     = 512   →  32 ms analysis window @ 16 kHz
///   * hopSize     = 256   →  ~62 Hz update rate (16 ms between callbacks)
///   * temporalEMA = 0.35  →  ~3-frame visible decay (~50 ms)
///
/// Thread safety: every call to `push` / `reset` and the resulting
/// `output` callback fires on whatever thread invokes `push`.  In subshout
/// that's the AVAudioEngine tap thread, which is single-threaded — so we
/// don't bother with locks.  The callback is responsible for hopping to
/// main before touching UI state.
final class FrequencyAnalyzer {
    static let fftSize = 512
    static let halfN = fftSize / 2
    static let hopSize = fftSize / 2          // 50% overlap
    static let bandCount = 21

    /// Voice-band lower edge.  We started at 60 Hz, but the bottom two
    /// bands almost never lit up during normal speech — speech energy is
    /// concentrated above ~120 Hz, and the rumble floor below that just
    /// makes the leftmost bars feel dead.  120 Hz lops off two empty
    /// bands so every visible bar earns its keep.  8 kHz is the Nyquist
    /// limit at our 16 kHz sample rate.
    static let lowFreq: Double = 120
    static let highFreq: Double = 8_000
    static let sampleRate: Double = 16_000

    /// Smoothing constant per band, frame-to-frame.  Higher = stickier.
    /// At 62 Hz update rate, 0.35 means the meter is ~99% caught up after
    /// 4–5 frames (~70 ms) — visibly less jumpy than 0.20 without feeling
    /// laggy when you snap.
    private static let temporalEMA: Float = 0.35

    /// AGC: a running-max magnitude is decayed by this factor every frame.
    /// At 62 Hz, 0.9985^310 ≈ 0.63, so a peak fades to ~63% over 5 s.
    /// Lower = faster auto-leveling (and more bouncy); higher = stickier.
    private static let agcDecay: Float = 0.9985
    /// Floor on the AGC reference so silence doesn't divide by zero.
    private static let agcFloor: Float = 1e-3

    /// Called with a fresh `[bandCount]`-sized array of magnitudes once
    /// per `hopSize` samples.  Called on the same thread as `push`.
    var output: ([Float]) -> Void = { _ in }

    // MARK: - Internals

    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private let bandBins: [(start: Int, end: Int)]

    // Audio ring buffer, length = fftSize.  After each window we slide
    // its contents back by `hopSize` and continue filling — that's how
    // we get overlapping analysis windows.
    private var ringBuffer: [Float]
    private var ringWriteIdx = 0

    // Pre-allocated scratch so processWindow doesn't touch the heap.
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var mags: [Float]
    private var smoothedBands: [Float]

    // AGC state.  `Self.agcFloor` would be neater, but Swift forbids
    // covariant-`Self` in a stored-property initializer; spell out the
    // type instead.
    private var agcReference: Float = FrequencyAnalyzer.agcFloor

    init() {
        let n = Self.fftSize
        precondition(n.nonzeroBitCount == 1, "fftSize must be a power of two")
        let log2N = vDSP_Length(Int(log2(Double(n))))

        guard let fft = vDSP.FFT(log2n: log2N, radix: .radix2, ofType: DSPSplitComplex.self) else {
            fatalError("vDSP.FFT init failed for log2n=\(log2N)")
        }
        self.fft = fft

        // Hann window — symmetric, peaks at 0.5.
        self.window = (0..<n).map { i in
            0.5 - 0.5 * cosf(2 * .pi * Float(i) / Float(n - 1))
        }

        self.ringBuffer = Array(repeating: 0, count: n)
        self.windowed = Array(repeating: 0, count: n)
        self.realp = Array(repeating: 0, count: Self.halfN)
        self.imagp = Array(repeating: 0, count: Self.halfN)
        self.mags = Array(repeating: 0, count: Self.halfN)
        self.smoothedBands = Array(repeating: 0, count: Self.bandCount)

        // Pre-compute the FFT-bin index range for each visual band.
        let binWidthHz = Self.sampleRate / Double(n)   // Hz per FFT bin
        let logLow = log(Self.lowFreq)
        let logHigh = log(Self.highFreq)
        let step = (logHigh - logLow) / Double(Self.bandCount)

        var ranges: [(Int, Int)] = []
        ranges.reserveCapacity(Self.bandCount)
        for i in 0..<Self.bandCount {
            let f0 = exp(logLow + step * Double(i))
            let f1 = exp(logLow + step * Double(i + 1))
            // Clamp to [1, halfN-1].  Bin 0 is DC; bin halfN holds the
            // Nyquist real component (packed into imagp[0] in vDSP form)
            // — both useless visually.
            let b0 = max(1, Int(f0 / binWidthHz))
            let b1 = max(b0 + 1, min(Self.halfN - 1, Int(f1 / binWidthHz)))
            ranges.append((b0, b1))
        }
        self.bandBins = ranges
    }

    // MARK: - Public

    /// Reset internal state.  Call on every recording start so old samples
    /// don't bleed into the first frame.
    func reset() {
        ringWriteIdx = 0
        for i in 0..<ringBuffer.count { ringBuffer[i] = 0 }
        for i in 0..<smoothedBands.count { smoothedBands[i] = 0 }
        agcReference = Self.agcFloor
    }

    /// Append `count` mono float samples.  Whenever the ring buffer has
    /// grown by `hopSize` past the previous analysis point we run one
    /// FFT pass and invoke `output`.
    func push(_ samples: UnsafePointer<Float>, count: Int) {
        var i = 0
        while i < count {
            let toWrite = min(count - i, Self.fftSize - ringWriteIdx)
            ringBuffer.withUnsafeMutableBufferPointer { rb -> Void in
                memcpy(
                    rb.baseAddress!.advanced(by: ringWriteIdx),
                    samples.advanced(by: i),
                    toWrite * MemoryLayout<Float>.stride
                )
            }
            ringWriteIdx += toWrite
            i += toWrite
            if ringWriteIdx >= Self.fftSize {
                processWindow()
                // Slide: keep the back (fftSize - hopSize) samples by
                // shifting them to the front; resume filling at hopSize.
                let keep = Self.fftSize - Self.hopSize
                ringBuffer.withUnsafeMutableBufferPointer { rb -> Void in
                    memmove(
                        rb.baseAddress!,
                        rb.baseAddress!.advanced(by: Self.hopSize),
                        keep * MemoryLayout<Float>.stride
                    )
                }
                ringWriteIdx = keep
            }
        }
    }

    // MARK: - Internals

    private func processWindow() {
        // 1) Hann window the buffered samples.
        vDSP.multiply(ringBuffer, window, result: &windowed)

        // 2) Pack real signal into split-complex form: realp[i] = sample[2i],
        //    imagp[i] = sample[2i+1].  Standard vDSP setup for an N-real ↦
        //    N/2-complex FFT.
        windowed.withUnsafeBufferPointer { wp in
            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.halfN) { complex in
                realp.withUnsafeMutableBufferPointer { rp in
                    imagp.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(
                            realp: rp.baseAddress!, imagp: ip.baseAddress!
                        )
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(Self.halfN))
                    }
                }
            }
        }

        // 3) In-place forward FFT, then magnitudes.
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(
                    realp: rp.baseAddress!, imagp: ip.baseAddress!
                )
                fft.forward(input: split, output: &split)
                vDSP.absolute(split, result: &mags)
            }
        }

        // 4) AGC: track a slowly-decaying running max so that "loud" maps
        //    to ~1.0 and "quiet relative to recent loud" maps low.  Skip
        //    bin 0 (DC) and the last bin (Nyquist quirk in real-input vDSP
        //    output, where imagp[0] holds the Nyquist real component).
        var frameMax: Float = 0
        for k in 1..<(Self.halfN - 1) {
            if mags[k] > frameMax { frameMax = mags[k] }
        }
        agcReference = max(agcReference * Self.agcDecay, frameMax)
        let invRef = 1.0 / max(agcReference, Self.agcFloor)

        // 5) Bin into bands, normalize, sqrt curve, EMA.
        let alpha = Self.temporalEMA
        for i in 0..<Self.bandCount {
            let (start, end) = bandBins[i]
            var sum: Float = 0
            for k in start..<end { sum += mags[k] }
            let avg = sum / Float(end - start)

            // Normalize against AGC reference, sqrt to spread quiet sounds.
            let normalized = sqrtf(max(0, min(1, avg * invRef)))

            smoothedBands[i] =
                alpha * smoothedBands[i] + (1 - alpha) * normalized
        }

        // 6) Hand a copy out.  21 floats = 84 bytes; cheap.
        output(smoothedBands)
    }
}
