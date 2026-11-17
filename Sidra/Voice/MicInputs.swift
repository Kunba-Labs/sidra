import AVFoundation
#if os(macOS)
import CoreAudio
import AudioToolbox
#endif

/// The microphones dictation can listen to, and which one it uses. The pick is saved by the device's
/// UID; nil (or a device that is gone) is the system's default input.
enum MicInputs {
    struct Device: Identifiable, Hashable { let id: String; let name: String }
    static let key = "sidra.voiceInput"

    static var chosen: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    #if os(macOS)
    /// Every device with an input stream, by name.
    static func all() -> [Device] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(id: uid, name: name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Points the engine's input at the chosen device before it starts; the default when none is chosen
    /// or it is gone.
    static func apply(to engine: AVAudioEngine) {
        guard let uid = chosen, let device = deviceID(uid), let unit = engine.inputNode.audioUnit else { return }
        var id = device
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func deviceID(_ uid: String) -> AudioDeviceID? {
        all().contains { $0.id == uid } ? translate(uid) : nil
    }

    private static func translate(_ uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf = uid as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cf) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<CFString>.size), p, &size, &id)
        }
        return status == noErr && id != 0 ? id : nil
    }
    #else
    /// The session's inputs (built-in, a headset, a USB or Bluetooth microphone).
    static func all() -> [Device] {
        let s = AVAudioSession.sharedInstance()
        if s.category != .record && s.category != .playAndRecord { try? s.setCategory(.record, mode: .measurement) }
        return (s.availableInputs ?? []).map { Device(id: $0.uid, name: $0.portName) }
    }

    /// The chosen input as the session's preferred one; the default when none is chosen or it is gone.
    static func apply(to engine: AVAudioEngine) {
        let s = AVAudioSession.sharedInstance()
        let port = chosen.flatMap { uid in s.availableInputs?.first { $0.uid == uid } }
        try? s.setPreferredInput(port)
    }
    #endif
}
