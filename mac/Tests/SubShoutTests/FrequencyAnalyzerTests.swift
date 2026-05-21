import XCTest
@testable import SubShout

/// Pure numerics — no AppKit, no audio device.  These tests guard against
/// regressions that would either crash the analyzer (bad indexing,
/// ring-buffer off-by-ones) or make the visualizer feel wrong (NaN / out
/// of `[0,1]` outputs).
final class FrequencyAnalyzerTests: XCTestCase {

    /// Run `samples` through the analyzer and collect every emitted frame.
    private func collectBands(samples: [Float]) -> [[Float]] {
        let a = FrequencyAnalyzer()
        var collected: [[Float]] = []
        a.output = { collected.append($0) }
        samples.withUnsafeBufferPointer { p in
            a.push(p.baseAddress!, count: samples.count)
        }
        return collected
    }

    func testSilenceProducesQuietOutput() {
        // 4 windows worth of zeros (>= a few hops).  Every output must be
        // a length-21 array of values clamped to [0, 1] with no NaNs.
        let n = FrequencyAnalyzer.fftSize * 4
        let frames = collectBands(samples: Array(repeating: 0, count: n))
        XCTAssertGreaterThan(frames.count, 0)
        for f in frames {
            XCTAssertEqual(f.count, FrequencyAnalyzer.bandCount)
            for v in f {
                XCTAssertFalse(v.isNaN, "NaN in band output")
                XCTAssertGreaterThanOrEqual(v, 0)
                XCTAssertLessThanOrEqual(v, 1)
                // Silence + AGC floor → bars should sit very low.
                XCTAssertLessThan(v, 0.1, "silence should not lift bars")
            }
        }
    }

    func testToneLightsUpAtLeastOneBand() {
        // 1 kHz sine → energy concentrated in one mid-range band.
        // After AGC settles + EMA catches up, at least one band should
        // be clearly above silence.
        let sr: Float = Float(FrequencyAnalyzer.sampleRate)
        let f: Float = 1_000
        let n = FrequencyAnalyzer.fftSize * 12   // ~24 hops, lots of warmup
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n {
            samples[i] = sinf(2 * .pi * f * Float(i) / sr)
        }

        let frames = collectBands(samples: samples)
        XCTAssertGreaterThan(frames.count, 0)
        // Inspect the *last* frame so the EMA / AGC have stabilized.
        let last = frames.last!
        let peak = last.max() ?? 0
        XCTAssertGreaterThan(peak, 0.4, "tone failed to lift any band; got max=\(peak)")
    }

    func testHopCountMatchesExpectedRate() {
        // Pushing exactly one fftSize block should emit exactly one frame
        // (the first window).  Pushing fftSize + N*hopSize blocks should
        // emit 1 + N frames.
        let a = FrequencyAnalyzer()
        var count = 0
        a.output = { _ in count += 1 }
        let zeros = Array(repeating: Float(0),
                          count: FrequencyAnalyzer.fftSize + 3 * FrequencyAnalyzer.hopSize)
        zeros.withUnsafeBufferPointer { p in
            a.push(p.baseAddress!, count: zeros.count)
        }
        XCTAssertEqual(count, 4)
    }

    func testResetClearsState() {
        // After reset, the analyzer behaves the same as a fresh instance:
        // the next batch of zeros should still emit `count`-many frames
        // starting from the cleared state.
        let a = FrequencyAnalyzer()
        var first: [Float] = []
        a.output = { first = $0 }

        // Prime with a short tone burst.
        let sr: Float = Float(FrequencyAnalyzer.sampleRate)
        var burst = [Float](repeating: 0, count: FrequencyAnalyzer.fftSize)
        for i in 0..<burst.count {
            burst[i] = sinf(2 * .pi * 1000 * Float(i) / sr)
        }
        burst.withUnsafeBufferPointer { p in a.push(p.baseAddress!, count: burst.count) }
        let nonZero = first.contains(where: { $0 > 0.01 })
        XCTAssertTrue(nonZero, "burst should have lit a band")

        // Reset → silence → bars should be approximately zero again.
        a.reset()
        let zeros = Array(repeating: Float(0), count: FrequencyAnalyzer.fftSize)
        zeros.withUnsafeBufferPointer { p in a.push(p.baseAddress!, count: zeros.count) }
        for v in first {
            XCTAssertLessThan(v, 0.5, "reset didn't quiet the analyzer")
        }
    }

    func testBandCountMatchesPillExpectations() {
        // The pill view is sized for 21 bars.  If anyone bumps bandCount
        // they need to update PillView constants to match — this test is
        // the canary.
        XCTAssertEqual(FrequencyAnalyzer.bandCount, 21)
        XCTAssertEqual(LevelStore.barCount, FrequencyAnalyzer.bandCount)
    }
}
