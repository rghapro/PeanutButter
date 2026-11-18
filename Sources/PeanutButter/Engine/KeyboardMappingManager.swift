import Foundation
import AppKit
import Combine
import SwiftUI

/// Represents a single mapped Keyboard shortcut
public struct KeyboardMappingItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var targetId: String
    public var keyCode: UInt16
    public var characters: String
    public var displayString: String
    
    public init(id: UUID = UUID(), targetId: String, keyCode: UInt16, characters: String, displayString: String) {
        self.id = id
        self.targetId = targetId
        self.keyCode = keyCode
        self.characters = characters
        self.displayString = displayString
    }
    
    public static func displayString(for keyCode: UInt16, characters: String) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "Enter"
        case 48: return "Tab"
        case 51: return "Del"
        case 53: return "Esc"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            let trimmed = characters.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed.uppercased()
            }
            return "#\(keyCode)"
        }
    }
}

/// Central manager for Keyboard mapping learning, storage, key event interception, and action dispatching
@MainActor
public final class KeyboardMappingManager: ObservableObject {
    public static let shared = KeyboardMappingManager()
    
    private let userDefaultsKey = "PeanutButter_KeyboardMappings_v1"
    
    /// TargetId -> KeyboardMappingItem
    @Published public private(set) var mappings: [String: KeyboardMappingItem] = [:]
    
    /// Target currently highlighted in white awaiting keyboard learning
    @Published public var selectedTargetId: String? = nil
    
    /// Target currently pending unassign confirmation
    @Published public var pendingUnassignTarget: (targetId: String, mapping: KeyboardMappingItem)? = nil
    
    /// Controls presentation of "Delete All" confirmation alert
    @Published public var isShowingDeleteAllAlert: Bool = false
    
    /// Collision prompt when pressed key is already assigned to a different control
    @Published public var pendingCollision: (existingTargetId: String, newTargetId: String, mapping: KeyboardMappingItem)? = nil
    
    public static func friendlyTargetName(_ targetId: String) -> String {
        switch targetId {
        case "play_pause": return "Play / Pause"
        case "restart_song": return "Return to Zero"
        case "fade_out": return "Fade Out"
        case "select_action": return "Select / Fire"
        case "prev_song": return "Previous Song"
        case "next_song": return "Next Song"
        case "prev_section": return "Previous Section"
        case "next_section": return "Next Section"
        case "tap_tempo": return "Tap Tempo"
        case "toggle_pad": return "Toggle Pad"
        case "mute_midi": return "Mute MIDI"
        case "toggle_single_loop": return "Single Loop"
        case "toggle_infinite_loop": return "Infinite Loop"
        case "transition": return "Transition"
        case "buses_button": return "Buses"
        case "pad_player_button": return "Pad Player"
        case "master_volume": return "Master Volume"
        default:
            if targetId.hasPrefix("song_card_"), let idx = Int(targetId.replacingOccurrences(of: "song_card_", with: "")) {
                return "Song \(idx + 1)"
            } else if targetId.hasPrefix("track_solo_") {
                return "Track Solo"
            } else if targetId.hasPrefix("track_mute_") {
                return "Track Mute"
            } else if targetId.hasPrefix("track_fader_") {
                return "Track Fader"
            }
            return targetId.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    
    /// Weak reference to MultitrackAudioEngine for executing mapped actions
    public weak var engine: MultitrackAudioEngine?
    
    private var mappingsFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("PeanutButter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("KeyboardMappings.json")
    }
    
    /// Default standard keyboard mappings for PeanutButter
    public static var defaultMappings: [String: KeyboardMappingItem] {
        var map: [String: KeyboardMappingItem] = [:]
        
        func add(targetId: String, keyCode: UInt16, chars: String, display: String) {
            let item = KeyboardMappingItem(targetId: targetId, keyCode: keyCode, characters: chars, displayString: display)
            map[targetId] = item
        }
        
        // Transport & Performance Hotkeys
        add(targetId: "play_pause", keyCode: 49, chars: " ", display: "Space")
        add(targetId: "restart_song", keyCode: 15, chars: "r", display: "R")
        add(targetId: "select_action", keyCode: 36, chars: "\r", display: "Enter")
        add(targetId: "prev_section", keyCode: 123, chars: "←", display: "←")
        add(targetId: "next_section", keyCode: 124, chars: "→", display: "→")
        add(targetId: "toggle_pad", keyCode: 35, chars: "p", display: "P")
        add(targetId: "fade_out", keyCode: 3, chars: "f", display: "F")
        add(targetId: "toggle_single_loop", keyCode: 37, chars: "l", display: "L")
        add(targetId: "toggle_infinite_loop", keyCode: 34, chars: "i", display: "I")
        
        // Song Selection Hotkeys 1 through 10
        add(targetId: "song_card_0", keyCode: 18, chars: "1", display: "1")
        add(targetId: "song_card_1", keyCode: 19, chars: "2", display: "2")
        add(targetId: "song_card_2", keyCode: 20, chars: "3", display: "3")
        add(targetId: "song_card_3", keyCode: 21, chars: "4", display: "4")
        add(targetId: "song_card_4", keyCode: 23, chars: "5", display: "5")
        add(targetId: "song_card_5", keyCode: 22, chars: "6", display: "6")
        add(targetId: "song_card_6", keyCode: 26, chars: "7", display: "7")
        add(targetId: "song_card_7", keyCode: 28, chars: "8", display: "8")
        add(targetId: "song_card_8", keyCode: 25, chars: "9", display: "9")
        add(targetId: "song_card_9", keyCode: 29, chars: "0", display: "0")
        
        return map
    }
    
    private init() {
        loadMappings()
    }
    
    // MARK: - Actions & Target Selection
    
    public func selectTarget(_ targetId: String) {
        if selectedTargetId == targetId {
            selectedTargetId = nil
        } else {
            selectedTargetId = targetId
        }
    }
    
    public func mapping(for targetId: String) -> KeyboardMappingItem? {
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
        saveMappings()
    }
    
    public func restoreDefaultMappings() {
        mappings = Self.defaultMappings
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
    
    /// Called by MainView key down monitor. Returns true if handled/intercepted.
    public func handleKeyDown(event: NSEvent) -> Bool {
        guard let eng = engine else { return false }
        
        // Never intercept keyboard mapping if Command or Control modifier is held
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            return false
        }
        
        let keyCode = event.keyCode
        // Escape key cancels target selection
        if keyCode == 53 && selectedTargetId != nil {
            selectedTargetId = nil
            return true
        }
        
        let chars = event.charactersIgnoringModifiers ?? ""
        let display = KeyboardMappingItem.displayString(for: keyCode, characters: chars)
        
        if eng.isEditKeyboardMappingMode {
            guard let targetId = selectedTargetId else { return false }
            
            // Check if existing mapping for this target has the same key
            if let existing = mappings[targetId], existing.keyCode == keyCode {
                pendingUnassignTarget = (targetId: targetId, mapping: existing)
            } else if let conflict = mappings.first(where: { $0.key != targetId && $0.value.keyCode == keyCode }) {
                let item = KeyboardMappingItem(targetId: targetId, keyCode: keyCode, characters: chars, displayString: display)
                pendingCollision = (existingTargetId: conflict.key, newTargetId: targetId, mapping: item)
            } else {
                let item = KeyboardMappingItem(targetId: targetId, keyCode: keyCode, characters: chars, displayString: display)
                mappings[targetId] = item
                selectedTargetId = nil
                saveMappings()
            }
            return true
        } else {
            // Live performance mode: check if any target is mapped to this keyCode
            if let match = mappings.values.first(where: { $0.keyCode == keyCode }) {
                executeAction(for: match.targetId)
                return true
            }
            return false
        }
    }
    
    public func executeAction(for targetId: String) {
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
        case "tap_tempo":
            eng.tapTempo()
        case "toggle_pad":
            eng.togglePadPlayer()
        case "mute_midi":
            eng.isMIDIMuted.toggle()
        case "toggle_single_loop":
            eng.toggleSingleLoop()
        case "toggle_infinite_loop":
            eng.toggleInfiniteLoop()
        case "transition":
            eng.cycleTransition()
        case "buses_button":
            eng.mixerMode = (eng.mixerMode == .busses ? .tracks : .busses)
        case "pad_player_button":
            eng.mixerMode = (eng.mixerMode == .padPlayer ? .tracks : .padPlayer)
        default:
            if targetId.hasPrefix("song_card_") {
                let indexStr = targetId.replacingOccurrences(of: "song_card_", with: "")
                if let idx = Int(indexStr), idx >= 0, idx < eng.currentSetlist.songs.count {
                    eng.selectSongInSetlist(at: idx)
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
    
    private func saveMappings() {
        if let data = try? JSONEncoder().encode(Array(mappings.values)) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
            UserDefaults.standard.synchronize()
            try? data.write(to: mappingsFileURL, options: .atomic)
        }
    }
    
    private func loadMappings() {
        var loaded: [String: KeyboardMappingItem] = [:]
        
        if let fileData = try? Data(contentsOf: mappingsFileURL),
           let list = try? JSONDecoder().decode([KeyboardMappingItem].self, from: fileData) {
            for item in list {
                loaded[item.targetId] = item
            }
        } else if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
                  let list = try? JSONDecoder().decode([KeyboardMappingItem].self, from: data) {
            for item in list {
                loaded[item.targetId] = item
            }
        }
        
        if loaded.isEmpty {
            loaded = Self.defaultMappings
        } else {
            // Merge defaults for any missing default targets where neither targetId nor keyCode is taken
            for (key, defaultItem) in Self.defaultMappings {
                if loaded[key] == nil && !loaded.values.contains(where: { $0.keyCode == defaultItem.keyCode }) {
                    loaded[key] = defaultItem
                }
            }
        }
        
        self.mappings = loaded
        saveMappings()
    }
}
