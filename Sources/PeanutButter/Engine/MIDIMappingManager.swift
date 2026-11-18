import Foundation
import CoreMIDI
import Combine
import SwiftUI

/// Represents a single mapped MIDI trigger
public struct MIDIMappingItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var targetId: String
    public var channel: Int // 1..16
    public var noteOrCC: Int // 0..127
    public var isNote: Bool // true for Note On, false for CC
    
    public init(id: UUID = UUID(), targetId: String, channel: Int, noteOrCC: Int, isNote: Bool) {
        self.id = id
        self.targetId = targetId
        self.channel = channel
        self.noteOrCC = noteOrCC
        self.isNote = isNote
    }
    
    public var displayString: String {
        if isNote {
            return "\(channel)/\(Self.noteDisplayName(for: noteOrCC))"
        } else {
            return "\(channel)/CC\(noteOrCC)"
        }
    }
    
    public static func noteDisplayName(for note: Int) -> String {
        let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let clamped = max(0, min(127, note))
        let name = noteNames[clamped % 12]
        let octave = (clamped / 12) - 2
        return "\(name)\(octave)"
    }
}

/// Central manager for MIDI mapping learning, storage, CoreMIDI input listening, and action dispatching
@MainActor
public final class MIDIMappingManager: ObservableObject {
    public static let shared = MIDIMappingManager()
    
    private let userDefaultsKey = "PeanutButter_MIDIMappings_v1"
    
    /// TargetId -> MIDIMappingItem
    @Published public private(set) var mappings: [String: MIDIMappingItem] = [:]
    
    /// Target currently highlighted in white awaiting MIDI learning
    @Published public var selectedTargetId: String? = nil
    
    /// Target currently pending unassign confirmation
    @Published public var pendingUnassignTarget: (targetId: String, mapping: MIDIMappingItem)? = nil
    
    /// Controls presentation of "Delete All" confirmation alert
    @Published public var isShowingDeleteAllAlert: Bool = false
    
    /// Collision prompt when incoming MIDI note/CC is already assigned to a different control
    @Published public var pendingCollision: (existingTargetId: String, newTargetId: String, mapping: MIDIMappingItem)? = nil
    
    /// Weak reference to MultitrackAudioEngine for executing mapped actions
    public weak var engine: MultitrackAudioEngine?
    
    private var midiClient: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0
    private var protocolPort: MIDIPortRef = 0
    
    private var lastHandledKey: String = ""
    private var lastHandledTime: TimeInterval = 0
    
    private init() {
        loadMappings()
        setupCoreMIDIInput()
    }
    
    deinit {
        if protocolPort != 0 {
            MIDIPortDispose(protocolPort)
        }
        if inputPort != 0 {
            MIDIPortDispose(inputPort)
        }
        if midiClient != 0 {
            MIDIClientDispose(midiClient)
        }
    }
    
    // MARK: - CoreMIDI Input Listening
    
    private func setupCoreMIDIInput() {
        let clientStatus = MIDIClientCreateWithBlock("PeanutButter MIDI Input Client" as CFString, &midiClient) { notificationPtr in
            let msgID = notificationPtr.pointee.messageID
            if msgID == .msgSetupChanged || msgID == .msgObjectAdded || msgID == .msgObjectRemoved {
                DispatchQueue.main.async {
                    MIDIMappingManager.shared.reconnectAllSources()
                }
            }
        }
        guard clientStatus == noErr else { return }
        
        let portStatus = MIDIInputPortCreateWithBlock(midiClient, "PeanutButter Input Port" as CFString, &inputPort) { pktList, _ in
            Self.processIncomingPacketList(pktList)
        }
        _ = portStatus
        
        if #available(macOS 11.0, *) {
            _ = MIDIInputPortCreateWithProtocol(midiClient, "PeanutButter Protocol Port" as CFString, ._1_0, &protocolPort) { eventListPtr, _ in
                Self.processIncomingEventList(eventListPtr)
            }
        }
        
        reconnectAllSources()
    }
    
    public func reconnectAllSources() {
        let sourceCount = MIDIGetNumberOfSources()
        for i in 0..<sourceCount {
            let src = MIDIGetSource(i)
            if inputPort != 0 {
                MIDIPortConnectSource(inputPort, src, nil)
            }
            if protocolPort != 0 {
                MIDIPortConnectSource(protocolPort, src, nil)
            }
        }
    }
    
    nonisolated private static func processIncomingPacketList(_ pktList: UnsafePointer<MIDIPacketList>) {
        let numPackets = Int(pktList.pointee.numPackets)
        guard numPackets > 0 else { return }
        
        var packetPtr = UnsafeRawPointer(pktList).advanced(by: MemoryLayout<UInt32>.size).assumingMemoryBound(to: MIDIPacket.self)
        let dataOffset = MemoryLayout<MIDITimeStamp>.size + MemoryLayout<UInt16>.size
        
        for _ in 0..<numPackets {
            let len = Int(packetPtr.pointee.length)
            if len >= 2 {
                let dataPtr = UnsafeRawPointer(packetPtr).advanced(by: dataOffset).assumingMemoryBound(to: UInt8.self)
                let status = dataPtr[0]
                let data1 = dataPtr[1]
                let data2 = len >= 3 ? dataPtr[2] : 0
                
                let messageType = status & 0xF0
                let channel = Int(status & 0x0F) + 1
                
                if messageType == 0x90 { // Note On
                    let note = Int(data1)
                    let velocity = Int(data2)
                    if velocity > 0 {
                        DispatchQueue.main.async {
                            MIDIMappingManager.shared.handleIncomingMIDI(channel: channel, number: note, isNote: true, value: velocity)
                        }
                    }
                } else if messageType == 0xB0 { // Control Change
                    let cc = Int(data1)
                    let val = Int(data2)
                    DispatchQueue.main.async {
                        MIDIMappingManager.shared.handleIncomingMIDI(channel: channel, number: cc, isNote: false, value: val)
                    }
                }
            }
            packetPtr = UnsafePointer(MIDIPacketNext(packetPtr))
        }
    }
    
    @available(macOS 11.0, *)
    nonisolated private static func processIncomingEventList(_ eventListPtr: UnsafePointer<MIDIEventList>) {
        let numPackets = Int(eventListPtr.pointee.numPackets)
        guard numPackets > 0 else { return }
        
        let headerOffset = MemoryLayout<MIDIProtocolID>.size + MemoryLayout<UInt32>.size
        var packetPtr = UnsafeRawPointer(eventListPtr).advanced(by: headerOffset).assumingMemoryBound(to: MIDIEventPacket.self)
        
        for _ in 0..<numPackets {
            let wordCount = Int(packetPtr.pointee.wordCount)
            let words = withUnsafePointer(to: packetPtr.pointee.words) {
                $0.withMemoryRebound(to: UInt32.self, capacity: wordCount) { Array(UnsafeBufferPointer(start: $0, count: wordCount)) }
            }
            for word in words {
                let messageType = (word >> 28) & 0x0F
                if messageType == 0x2 { // MIDI 1.0 Voice Message in UMP
                    let statusByte = UInt8((word >> 16) & 0xFF)
                    let data1 = UInt8((word >> 8) & 0xFF)
                    let data2 = UInt8(word & 0xFF)
                    
                    let cmd = statusByte & 0xF0
                    let channel = Int(statusByte & 0x0F) + 1
                    
                    if cmd == 0x90 { // Note On
                        let note = Int(data1)
                        let velocity = Int(data2)
                        if velocity > 0 {
                            DispatchQueue.main.async {
                                MIDIMappingManager.shared.handleIncomingMIDI(channel: channel, number: note, isNote: true, value: velocity)
                            }
                        }
                    } else if cmd == 0xB0 { // CC
                        let cc = Int(data1)
                        let val = Int(data2)
                        DispatchQueue.main.async {
                            MIDIMappingManager.shared.handleIncomingMIDI(channel: channel, number: cc, isNote: false, value: val)
                        }
                    }
                }
            }
            packetPtr = UnsafePointer(MIDIEventPacketNext(packetPtr))
        }
    }
    
    // MARK: - MIDI Message Handling & Learning
    
    public func handleIncomingMIDI(channel: Int, number: Int, isNote: Bool, value: Int) {
        let now = Date().timeIntervalSince1970
        let key = "\(channel)_\(number)_\(isNote)_\(value)"
        if key == lastHandledKey && (now - lastHandledTime) < 0.05 {
            return
        }
        lastHandledKey = key
        lastHandledTime = now
        
        guard let eng = engine else { return }
        
        if eng.isEditMIDIMappingMode {
            // In MIDI Mapping mode: learn or unassign
            guard let targetId = selectedTargetId else { return }
            
            if let existing = mappings[targetId],
               existing.channel == channel && existing.noteOrCC == number && existing.isNote == isNote {
                // Sent the same MIDI value as already mapped: trigger unassign confirmation
                pendingUnassignTarget = (targetId: targetId, mapping: existing)
            } else if let conflict = mappings.first(where: { $0.key != targetId && $0.value.channel == channel && $0.value.noteOrCC == number && $0.value.isNote == isNote }) {
                let item = MIDIMappingItem(targetId: targetId, channel: channel, noteOrCC: number, isNote: isNote)
                pendingCollision = (existingTargetId: conflict.key, newTargetId: targetId, mapping: item)
            } else {
                // Assign new mapping
                let item = MIDIMappingItem(targetId: targetId, channel: channel, noteOrCC: number, isNote: isNote)
                mappings[targetId] = item
                selectedTargetId = nil
                saveMappings()
            }
        } else {
            // Live performance mode: trigger mapped functionality
            if let match = mappings.values.first(where: { $0.channel == channel && $0.noteOrCC == number && $0.isNote == isNote }) {
                executeAction(for: match.targetId, value: value)
            }
        }
    }
    
    // MARK: - Actions
    
    public func selectTarget(_ targetId: String) {
        if selectedTargetId == targetId {
            selectedTargetId = nil
        } else {
            selectedTargetId = targetId
        }
    }
    
    public func mapping(for targetId: String) -> MIDIMappingItem? {
        return mappings[targetId]
    }
    
    public func removeMapping(for targetId: String) {
        mappings.removeValue(forKey: targetId)
        pendingUnassignTarget = nil
        saveMappings()
    }
    
    public func removeAllMappings() {
        mappings.removeAll()
        selectedTargetId = nil
        pendingUnassignTarget = nil
        pendingCollision = nil
        saveMappings()
    }
    
    public func confirmReassignCollision() {
        guard let collision = pendingCollision else { return }
        mappings.removeValue(forKey: collision.existingTargetId)
        mappings[collision.newTargetId] = collision.mapping
        selectedTargetId = nil
        pendingCollision = nil
        saveMappings()
    }
    
    public func cancelCollision() {
        pendingCollision = nil
    }
    
    public func executeAction(for targetId: String, value: Int) {
        guard let eng = engine else { return }
        
        switch targetId {
        case "play_pause":
            eng.togglePlayPause()
        case "fade_out":
            eng.toggleFade()
        case "restart_song":
            eng.seek(to: 0.0)
        case "prev_song":
            if eng.currentSongIndex > 0 {
                eng.selectSongInSetlist(at: eng.currentSongIndex - 1)
            }
        case "next_song":
            if eng.currentSongIndex + 1 < eng.currentSetlist.songs.count {
                eng.selectSongInSetlist(at: eng.currentSongIndex + 1)
            }
        case "prev_section":
            eng.navigatePreviousSection()
        case "next_section":
            eng.navigateNextSection()
        case "select_action":
            eng.triggerSelectAction()
        case "stop_cue":
            eng.triggerSelectAction()
        case "tap_tempo":
            eng.tapTempo()
        case "toggle_pad":
            eng.togglePadPlayer()
        case "mute_midi":
            eng.isMIDIMuted.toggle()
        case "toggle_single_loop":
            eng.toggleSingleLoop()
        case "toggle_infinite_loop":
            if let activeSection = eng.currentSong.sections.first(where: { eng.transportPosition.currentTime >= $0.startTime && eng.transportPosition.currentTime < $0.endTime }) {
                eng.toggleSectionLoop(activeSection)
            }
        case "transition":
            eng.cycleTransition()
        case "buses_button":
            eng.mixerMode = (eng.mixerMode == .busses ? .tracks : .busses)
        case "pad_player_button":
            eng.mixerMode = (eng.mixerMode == .padPlayer ? .tracks : .padPlayer)
        case "master_fader":
            eng.masterVolume = Float(value) / 127.0
        default:
            if targetId.hasPrefix("song_card_") {
                let indexStr = targetId.replacingOccurrences(of: "song_card_", with: "")
                if let idx = Int(indexStr), idx >= 0, idx < eng.currentSetlist.songs.count {
                    eng.selectSongInSetlist(at: idx)
                }
            } else if targetId.hasPrefix("track_fader_") {
                let idStr = targetId.replacingOccurrences(of: "track_fader_", with: "")
                if let uuid = UUID(uuidString: idStr), let track = eng.tracks.first(where: { $0.id == uuid }) {
                    track.volume = Float(value) / 127.0
                    eng.updateMatrix()
                }
            } else if targetId.hasPrefix("track_solo_") {
                let idStr = targetId.replacingOccurrences(of: "track_solo_", with: "")
                if let uuid = UUID(uuidString: idStr), let track = eng.tracks.first(where: { $0.id == uuid }) {
                    track.isSoloed.toggle()
                    eng.updateMatrix()
                }
            } else if targetId.hasPrefix("track_mute_") {
                let idStr = targetId.replacingOccurrences(of: "track_mute_", with: "")
                if let uuid = UUID(uuidString: idStr), let track = eng.tracks.first(where: { $0.id == uuid }) {
                    track.isMuted.toggle()
                    eng.updateMatrix()
                }
            }
        }
    }
    
    // MARK: - Persistence
    
    private var mappingsFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("PeanutButter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("MIDIMappings.json")
    }
    
    private func saveMappings() {
        if let data = try? JSONEncoder().encode(Array(mappings.values)) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
            UserDefaults.standard.synchronize()
            try? data.write(to: mappingsFileURL, options: .atomic)
        }
    }
    
    private func loadMappings() {
        if let fileData = try? Data(contentsOf: mappingsFileURL),
           let list = try? JSONDecoder().decode([MIDIMappingItem].self, from: fileData) {
            var map: [String: MIDIMappingItem] = [:]
            for item in list {
                map[item.targetId] = item
            }
            self.mappings = map
            return
        }
        
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let list = try? JSONDecoder().decode([MIDIMappingItem].self, from: data) else { return }
        var map: [String: MIDIMappingItem] = [:]
        for item in list {
            map[item.targetId] = item
        }
        self.mappings = map
        try? data.write(to: mappingsFileURL, options: .atomic)
    }
}
