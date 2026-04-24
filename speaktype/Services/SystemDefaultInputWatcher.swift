import AVFoundation
import Combine
import CoreAudio
import Foundation

/// Observes the macOS system default input device and publishes its
/// UID + localized name. Drives AudioRecordingService's "follow system
/// default" mode and the device-picker subtitle that shows the currently
/// resolved device.
///
/// Uses a Core Audio property listener on
/// kAudioHardwarePropertyDefaultInputDevice — the only reliable mechanism
/// to observe default-device changes on macOS. AVFoundation has no
/// equivalent notification (AVCaptureDeviceWasConnected/Disconnected
/// only fires on hardware plug/unplug, not on user changing default in
/// Sound Settings).
///
/// Singleton is held for app lifetime; the listener block is installed
/// once and never torn down (the overhead of a Core Audio block callback
/// that reads one integer is negligible).
@MainActor
final class SystemDefaultInputWatcher: ObservableObject {
    static let shared = SystemDefaultInputWatcher()

    /// UID (== AVCaptureDevice.uniqueID) of the current system default
    /// input, or nil when no device is available.
    @Published private(set) var currentDefaultUID: String?

    /// Human-readable device name, for UI subtitles like
    /// "System Default — MacBook Pro Microphone".
    @Published private(set) var currentDefaultDeviceName: String?

    private var listenerInstalled = false
    private var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private init() {
        refresh()
        installListener()
    }

    // MARK: - Public resolver

    /// Query Core Audio once for the current default input's UID and
    /// localized name. Returns (nil, nil) if there is no default input
    /// device (e.g. all mics unplugged).
    ///
    /// Aggregate devices — including macOS 26's auto-generated
    /// "CA default device aggregate" proxy — are transparently
    /// unwrapped to their first active subdevice. The aggregate can
    /// deliver samples to an AVAssetWriter (transcription works) but
    /// frequently mangles the amplitude profile, breaking our
    /// RMS-based level meter. Resolving to the underlying physical
    /// device fixes both the meter and any format assumptions
    /// downstream code makes about the capture source.
    static func resolveDefaultInput() -> (uid: String?, name: String?) {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return (nil, nil)
        }

        let physicalDeviceID = unwrapAggregate(deviceID)

        let uid = readCFStringProperty(
            physicalDeviceID,
            selector: kAudioDevicePropertyDeviceUID
        )
        let name = readCFStringProperty(
            physicalDeviceID,
            selector: kAudioObjectPropertyName
        )
        return (uid, name)
    }

    /// If `deviceID` is an aggregate device, return its first active
    /// subdevice; otherwise return `deviceID` unchanged. Aggregates
    /// are identified via `kAudioDevicePropertyTransportType`.
    static func unwrapAggregate(_ deviceID: AudioDeviceID) -> AudioDeviceID {
        guard isAggregateDevice(deviceID),
            let firstSub = firstActiveSubdevice(of: deviceID)
        else {
            return deviceID
        }
        return firstSub
    }

    /// True iff this Core Audio device has transport type "aggregate."
    static func isAggregateDevice(_ deviceID: AudioDeviceID) -> Bool {
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            deviceID, &addr, 0, nil, &size, &transportType
        )
        guard status == noErr else { return false }
        return transportType == kAudioDeviceTransportTypeAggregate
    }

    /// Return the first active subdevice of an aggregate, or nil if the
    /// aggregate has no active members or isn't actually an aggregate.
    static func firstActiveSubdevice(of aggregateID: AudioDeviceID) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &addr, 0, nil, &size) == noErr,
            size >= UInt32(MemoryLayout<AudioDeviceID>.size)
        else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var subdevices = [AudioDeviceID](repeating: 0, count: count)
        let status = subdevices.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            return AudioObjectGetPropertyData(
                aggregateID, &addr, 0, nil, &size, base
            )
        }
        guard status == noErr,
            let first = subdevices.first,
            first != kAudioObjectUnknown
        else { return nil }
        return first
    }

    // MARK: - Private

    private func refresh() {
        let (uid, name) = Self.resolveDefaultInput()
        currentDefaultUID = uid
        currentDefaultDeviceName = name
    }

    private func installListener() {
        guard !listenerInstalled else { return }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            // The listener block fires on the dispatch queue we pass —
            // here, main — so it's safe to mutate @Published state
            // directly.
            self?.refresh()
        }

        if status == noErr {
            listenerInstalled = true
        } else {
            print("⚠️ SystemDefaultInputWatcher: listener install failed with OSStatus \(status)")
        }
    }

    /// Read a CFString-valued Core Audio property on a specific device
    /// object. Returns nil on any Core Audio error.
    ///
    /// Uses `Unmanaged<CFString>?` as the out-param type — Core Audio
    /// writes a retained CFStringRef, and taking `takeRetainedValue()`
    /// correctly transfers ownership to ARC. Naively using
    /// `var value: CFString` and passing `&value` triggers a Swift
    /// compiler warning because CFString holds an object reference.
    private static func readCFStringProperty(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var unmanaged: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(
            deviceID, &addr, 0, nil, &size, &unmanaged
        )
        guard status == noErr, let cfString = unmanaged?.takeRetainedValue() else {
            return nil
        }
        return cfString as String
    }
}
