import AVFoundation

/// Resolves a saved device ID without changing the system-wide input device.
/// An empty preference follows the system default. Missing devices retain their
/// saved preference so reconnecting them restores the choice on the next take.
struct MicrophoneSelection {
    let deviceID: String?
    let usedFallback: Bool

    init(preferredID: String, availableIDs: [String], defaultID: String?) {
        if !preferredID.isEmpty, availableIDs.contains(preferredID) {
            deviceID = preferredID
            usedFallback = false
        } else {
            deviceID = defaultID
            usedFallback = !preferredID.isEmpty
        }
    }

    static func availableDevices() -> [AVCaptureDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        ).devices.sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
    }
}
