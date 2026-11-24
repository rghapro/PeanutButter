import Foundation
import CoreAudio
import AVFoundation

/// Represents a physical audio output device connected to the Mac
public struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let outputChannelCount: Int
    
    public init(id: AudioDeviceID, uid: String, name: String, outputChannelCount: Int) {
        self.id = id
        self.uid = uid
        self.name = name
        self.outputChannelCount = outputChannelCount
    }
}

/// Discovers and manages audio interfaces and physical output routing
@MainActor
public final class AudioDeviceManager: ObservableObject {
    public static let shared = AudioDeviceManager()

    public static let preferredDeviceUIDKey = "Playback_PreferredAudioDeviceUID"
    public static let preferredDeviceNameKey = "Playback_PreferredAudioDeviceName"
    
    @Published public private(set) var availableDevices: [AudioOutputDevice] = []
    @Published public var selectedDevice: AudioOutputDevice?

    public func persistPreferredDevice(_ device: AudioOutputDevice, defaults: UserDefaults = .standard) {
        if !device.uid.isEmpty {
            defaults.set(device.uid, forKey: Self.preferredDeviceUIDKey)
        }
        if !device.name.isEmpty {
            defaults.set(device.name, forKey: Self.preferredDeviceNameKey)
        }
    }

    public nonisolated static func resolveTargetDevice(
        from outputs: [AudioOutputDevice],
        currentSelected: AudioOutputDevice?,
        preferredUID: String?,
        preferredName: String?,
        systemDefaultID: AudioDeviceID?
    ) -> AudioOutputDevice? {
        guard !outputs.isEmpty else { return nil }

        if let pUID = preferredUID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pUID.isEmpty,
           let match = outputs.first(where: { $0.uid == pUID }) {
            return match
        }

        if let pName = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pName.isEmpty,
           let match = outputs.first(where: {
               $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(pName) == .orderedSame
           }) {
            return match
        }

        if let defaultID = systemDefaultID,
           let match = outputs.first(where: { $0.id == defaultID }) {
            return match
        }

        if let current = currentSelected {
            if let match = outputs.first(where: { $0.id == current.id }) {
                return match
            }
            if !current.uid.isEmpty, let match = outputs.first(where: { $0.uid == current.uid }) {
                return match
            }
            let curName = current.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !curName.isEmpty,
               let match = outputs.first(where: {
                   $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(curName) == .orderedSame
               }) {
                return match
            }
        }

        return outputs.first
    }
    
    public init() {
        refreshDevices()
        setupHardwareListeners()
    }
    
    private func setupHardwareListeners() {
        var defaultDevAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDevAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let newDefaultID = self.getDefaultSystemDeviceID()
                if let newID = newDefaultID, newID != self.selectedDevice?.id {
                    self.refreshDevices()
                }
            }
        }
        
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshDevices()
            }
        }
    }
    
    /// Queries macOS CoreAudio for the current active default system output device ID
    public func getDefaultSystemDeviceID() -> AudioDeviceID? {
        var defaultDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &defaultDeviceID
        )
        
        return status == noErr && defaultDeviceID != 0 ? defaultDeviceID : nil
    }
    
    public func refreshDevices() {
        var propertySize: UInt32 = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize
        )
        guard status == noErr else { return }
        
        let deviceCount = Int(propertySize / UInt32(MemoryLayout<AudioDeviceID>.size))
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        
        let getStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceIDs
        )
        guard getStatus == noErr else { return }
        
        var outputs: [AudioOutputDevice] = []
        for devID in deviceIDs {
            let channels = getOutputChannelCount(for: devID)
            if channels > 0 {
                let name = getDeviceName(for: devID)
                let uid = getDeviceUID(for: devID)
                outputs.append(AudioOutputDevice(id: devID, uid: uid, name: name, outputChannelCount: channels))
            }
        }
        
        self.availableDevices = outputs
        
        // Restore the user's preferred audio interface (by UID, then name fallback for USB port changes),
        // falling back to macOS System Default only if no preferred device is connected or saved.
        let defaults = UserDefaults.standard
        let preferredUID = defaults.string(forKey: Self.preferredDeviceUIDKey)
        let preferredName = defaults.string(forKey: Self.preferredDeviceNameKey)
        let systemDefaultID = getDefaultSystemDeviceID()
        if let target = Self.resolveTargetDevice(
            from: outputs,
            currentSelected: selectedDevice,
            preferredUID: preferredUID,
            preferredName: preferredName,
            systemDefaultID: systemDefaultID
        ) {
            if let pName = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !pName.isEmpty,
               target.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(pName) == .orderedSame,
               !target.uid.isEmpty,
               target.uid != preferredUID {
                defaults.set(target.uid, forKey: Self.preferredDeviceUIDKey)
            }
            if self.selectedDevice?.id != target.id ||
               self.selectedDevice?.uid != target.uid ||
               self.selectedDevice?.outputChannelCount != target.outputChannelCount {
                self.selectedDevice = target
            }
        }
    }
    
    /// Returns dynamic stereo pair labels and mono channel labels based on the selected hardware interface
    public func availableOutputs(for device: AudioOutputDevice?) -> (stereo: [String], mono: [String]) {
        let count = max(2, device?.outputChannelCount ?? 2)
        var stereo: [String] = []
        let pairs = count / 2
        for i in 0..<pairs {
            let ch1 = (i * 2) + 1
            let ch2 = (i * 2) + 2
            stereo.append("Out \(ch1)/\(ch2)")
        }
        var mono: [String] = []
        for i in 1...count {
            mono.append("Out \(i)")
        }
        return (stereo, mono)
    }
    
    private func getDeviceName(for deviceID: AudioDeviceID) -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &propertySize)
        guard status == noErr, propertySize > 0 else { return "Audio Device (\(deviceID))" }
        
        var nameCF: Unmanaged<CFString>? = nil
        var cfSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let getStatus = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &cfSize, &nameCF)
        if getStatus == noErr, let resolved = nameCF?.takeRetainedValue() as String? {
            return resolved
        }
        return "Audio Device (\(deviceID))"
    }
    
    private func getDeviceUID(for deviceID: AudioDeviceID) -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidCF: Unmanaged<CFString>? = nil
        var cfSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &cfSize, &uidCF)
        if status == noErr, let resolved = uidCF?.takeRetainedValue() as String? {
            return resolved
        }
        return UUID().uuidString
    }
    
    private func getOutputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &propertySize)
        guard status == noErr, propertySize > 0 else { return 0 }
        
        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(propertySize))
        defer { bufferListPointer.deallocate() }
        
        let getStatus = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, bufferListPointer)
        guard getStatus == noErr else { return 0 }
        
        let bufferList = bufferListPointer.pointee
        var channelCount = 0
        let buffers = UnsafeBufferPointer<AudioBuffer>(
            start: &bufferListPointer.pointee.mBuffers,
            count: Int(bufferList.mNumberBuffers)
        )
        for buffer in buffers {
            channelCount += Int(buffer.mNumberChannels)
        }
        return channelCount
    }
}
