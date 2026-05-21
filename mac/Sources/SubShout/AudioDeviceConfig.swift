import CoreAudio
import Foundation
import OSLog

/// Configures the system's default input device for low-latency capture
/// by writing `kAudioDevicePropertyBufferFrameSize`.
///
/// ## Why
///
/// `AVAudioEngine.installTap(..., bufferSize:, ...)` is documented as
/// supporting a 100 ms minimum buffer.  100 ms is the *AVAudioEngine
/// convenience layer's* floor — the underlying CoreAudio device routinely
/// runs at 64–512 frames (1–10 ms at 48 kHz).  If we shrink the *hardware*
/// buffer here, AVAudioEngine's tap rides on top of those small buffers
/// and we get the same low latency a pro audio app would, while staying
/// inside CoreAudio's documented contract.
///
/// ## Save & restore
///
/// Buffer size is a *per-device* property — every client of the input
/// device sees the same value.  We read the original on `configure(...)`
/// and write it back on `restore()` so we don't leave another app stuck
/// with our preferences.  `deinit` restores too, in case we're released
/// without an explicit stop.
///
/// ## Failure modes
///
/// Every CoreAudio call here can fail.  We log and bail; we never throw.
/// If anything goes wrong, AVAudioEngine still runs, just at whatever
/// buffer size the device happens to default to.  The visualizer will be
/// laggy but transcription is unaffected.
final class AudioDeviceConfig {
    private let log = Logger(subsystem: "com.cameronfranke.SubShout", category: "AudioDeviceConfig")

    private var device: AudioDeviceID = 0
    private var savedFrames: UInt32?

    /// Returns the buffer size that's now in effect on the input device.
    /// May differ from `targetFrames` if the device clamped to its range
    /// or rejected the request — in which case we return whatever the
    /// device is actually using.
    @discardableResult
    func configureLowLatencyInput(targetFrames: UInt32 = 256) -> UInt32 {
        guard let dev = Self.defaultInputDevice() else {
            log.warning("no default input device; can't configure")
            return targetFrames
        }
        guard let current = Self.bufferFrameSize(of: dev) else {
            log.warning("could not read current buffer frame size")
            return targetFrames
        }

        // Clamp to the device's allowed range if it'll tell us.
        let desired: UInt32
        if let range = Self.bufferFrameSizeRange(of: dev) {
            let lo = UInt32(range.mMinimum)
            let hi = UInt32(range.mMaximum)
            desired = max(lo, min(hi, targetFrames))
            log.info(
                "input device buffer: current=\(current) range=\(lo)…\(hi) target=\(desired)"
            )
        } else {
            desired = targetFrames
            log.info("input device buffer: current=\(current) target=\(desired) (no range info)")
        }

        if desired == current {
            // Nothing to do.  Don't record `savedFrames` so `restore()` is a no-op.
            self.device = dev
            return current
        }

        if Self.setBufferFrameSize(of: dev, frames: desired) {
            // Confirm what actually took.  Some drivers report success but
            // round to a nearby supported size.
            let actual = Self.bufferFrameSize(of: dev) ?? desired
            self.device = dev
            self.savedFrames = current
            log.info("input device buffer set: \(current) → \(actual)")
            return actual
        } else {
            log.warning("setBufferFrameSize(\(desired)) failed; staying at \(current)")
            return current
        }
    }

    /// Restore the saved buffer frame size if we changed it.  Idempotent.
    func restore() {
        guard device != 0, let saved = savedFrames else {
            device = 0
            savedFrames = nil
            return
        }
        if Self.setBufferFrameSize(of: device, frames: saved) {
            log.info("input device buffer restored to \(saved)")
        } else {
            log.warning("could not restore input device buffer to \(saved)")
        }
        device = 0
        savedFrames = nil
    }

    deinit { restore() }

    // MARK: - CoreAudio plumbing

    private static func defaultInputDevice() -> AudioDeviceID? {
        var dev: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &dev
        )
        return (status == noErr && dev != 0) ? dev : nil
    }

    private static func bufferFrameSize(of device: AudioDeviceID) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func bufferFrameSizeRange(of device: AudioDeviceID) -> AudioValueRange? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &range)
        return status == noErr ? range : nil
    }

    @discardableResult
    private static func setBufferFrameSize(of device: AudioDeviceID, frames: UInt32) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = frames
        let status = AudioObjectSetPropertyData(
            device, &addr, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &value
        )
        return status == noErr
    }
}
