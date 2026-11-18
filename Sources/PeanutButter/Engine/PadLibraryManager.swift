import Foundation
import AVFoundation
import AppKit

/// Represents an ambient pad sound library pack containing 12 key audio tracks
public struct PadSoundPack: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var name: String
    public var subtitle: String
    public var folderPath: String?
    public var isBundled: Bool
    
    public init(id: String, name: String, subtitle: String, folderPath: String? = nil, isBundled: Bool = false) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.folderPath = folderPath
        self.isBundled = isBundled
    }
}

public enum PadRenameError: LocalizedError {
    case emptyName
    case unchanged
    case reservedName
    case duplicateName(String)
    case notFound
    case moveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Enter a pad pack name."
        case .unchanged:
            return nil
        case .reservedName:
            return "\"Simple\" and \"Soft\" are reserved for built-in pads."
        case .duplicateName(let name):
            return "A pad pack named \"\(name)\" already exists."
        case .notFound:
            return "Custom pad folder not found on disk."
        case .moveFailed(let reason):
            return "Could not rename folder: \(reason)"
        }
    }
}

/// Central manager for ambient pad audio packs (bundled Fundamental, imported, or user-uploaded)
public final class PadLibraryManager: ObservableObject, @unchecked Sendable {
    public static let shared = PadLibraryManager()
    
    @Published public var availablePacks: [PadSoundPack] = []
    @Published public var activePackId: String = "simple"
    
    private let customPadsDirectory: URL
    
    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.customPadsDirectory = appSupport.appendingPathComponent("PeanutButter").appendingPathComponent("Pads")
        let savedDefault = UserDefaults.standard.string(forKey: "Playback_DefaultAmbientPadId") ?? "simple"
        self.activePackId = (savedDefault == "fundamental") ? "simple" : savedDefault
        
        try? FileManager.default.createDirectory(at: customPadsDirectory, withIntermediateDirectories: true)
        
        reloadPacks()
    }
    
    public var activePack: PadSoundPack {
        availablePacks.first(where: { $0.id == activePackId }) ?? availablePacks.first ?? PadSoundPack(id: "simple", name: "Simple", subtitle: "PeanutButterPads", isBundled: true)
    }
    
    public func reloadPacks() {
        var packs: [PadSoundPack] = [
            PadSoundPack(id: "simple", name: "Simple", subtitle: "PeanutButterPads", isBundled: true),
            PadSoundPack(id: "soft", name: "Soft", subtitle: "PeanutButterPads", isBundled: true)
        ]
        
        // Scan custom pads folder (Local Application Support + optional Cloud Pads)
        let fm = FileManager.default
        var customFoldersScanned: Set<String> = []
        let scanDirectories: [(url: URL, subtitle: String)] = {
            var dirs: [(URL, String)] = [(customPadsDirectory, "Custom Pad")]
            if let cloudPadsDir = LibraryBrowserManager.cloudPadsDirectoryURL {
                dirs.append((cloudPadsDir, "Cloud Custom Pad"))
            }
            return dirs
        }()
        for entry in scanDirectories {
            if let subdirs = try? fm.contentsOfDirectory(at: entry.url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for sub in subdirs {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue {
                        let folderName = sub.lastPathComponent
                        guard !customFoldersScanned.contains(folderName.lowercased()) else { continue }
                        customFoldersScanned.insert(folderName.lowercased())
                        let pack = PadSoundPack(
                            id: sub.path,
                            name: folderName,
                            subtitle: entry.subtitle,
                            folderPath: sub.path,
                            isBundled: false
                        )
                        packs.append(pack)
                    }
                }
            }
        }
        
        let applyPacks = {
            self.availablePacks = packs
            if !packs.contains(where: { $0.id == self.activePackId }) {
                self.activePackId = "simple"
            }
        }
        if Thread.isMainThread {
            applyPacks()
        } else {
            DispatchQueue.main.async(execute: applyPacks)
        }
    }
    
    public func selectPack(id: String) {
        activePackId = id
    }
    
    /// Deletes a custom (non-bundled) pad pack from Application Support and falls back to Fundamental if active (4.7).
    public func deletePack(id: String) {
        guard let pack = availablePacks.first(where: { $0.id == id }), !pack.isBundled else { return }
        if let folderPath = pack.folderPath {
            try? FileManager.default.removeItem(atPath: folderPath)
        }
        if activePackId == id {
            activePackId = "simple"
        }
        if UserDefaults.standard.string(forKey: "Playback_DefaultAmbientPadId") == id {
            UserDefaults.standard.set("simple", forKey: "Playback_DefaultAmbientPadId")
        }
        reloadPacks()
    }

    /// Renames a custom (non-bundled) pad pack folder on disk and returns its new pack ID, or nil if invalid/failed.
    @discardableResult
    public func renamePack(id: String, newName: String) -> String? {
        if case .success(let newId) = renamePackWithResult(id: id, newName: newName) {
            return newId
        }
        return nil
    }

    /// Renames a custom (non-bundled) pad pack folder on disk and returns either its new pack ID or a structured error.
    public func renamePackWithResult(id: String, newName: String) -> Result<String, PadRenameError> {
        let trimmed = newName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let sanitized = String(trimmed.drop(while: { $0 == "." }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return .failure(.emptyName) }

        let lowerSanitized = sanitized.lowercased()
        if lowerSanitized == "simple" || lowerSanitized == "soft" {
            return .failure(.reservedName)
        }

        guard let pack = availablePacks.first(where: { $0.id == id }),
              !pack.isBundled,
              let folderPath = pack.folderPath else {
            return .failure(.notFound)
        }

        let oldURL = URL(fileURLWithPath: folderPath)
        let fm = FileManager.default
        guard fm.fileExists(atPath: oldURL.path) else {
            return .failure(.notFound)
        }

        if oldURL.lastPathComponent == sanitized {
            return .failure(.unchanged)
        }

        let hasExistingPackConflict = availablePacks.contains { other in
            other.id != id && !other.isBundled && other.name.lowercased() == lowerSanitized
        }
        if hasExistingPackConflict {
            return .failure(.duplicateName(sanitized))
        }

        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(sanitized)
        let isCaseOnlyRename = oldURL.lastPathComponent.lowercased() == lowerSanitized
        if !isCaseOnlyRename && fm.fileExists(atPath: newURL.path) {
            return .failure(.duplicateName(sanitized))
        }

        do {
            if isCaseOnlyRename {
                let tempURL = oldURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)_\(sanitized)")
                try fm.moveItem(at: oldURL, to: tempURL)
                try fm.moveItem(at: tempURL, to: newURL)
            } else {
                try fm.moveItem(at: oldURL, to: newURL)
            }
        } catch {
            return .failure(.moveFailed(error.localizedDescription))
        }

        let newId = newURL.path
        if activePackId == id {
            activePackId = newId
        }
        if UserDefaults.standard.string(forKey: "Playback_DefaultAmbientPadId") == id {
            UserDefaults.standard.set(newId, forKey: "Playback_DefaultAmbientPadId")
        }
        reloadPacks()
        return .success(newId)
    }
    
    public func promptUploadPadPack(completion: @escaping (Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = "Import Ambient Pad Sound Pack"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.audio, .folder]
        
        panel.begin { [weak self] response in
            guard let self = self, response == .OK, !panel.urls.isEmpty else {
                completion(false)
                return
            }
            
            let fm = FileManager.default
            let firstURL = panel.urls[0]
            var isDir: ObjCBool = false
            
            if panel.urls.count == 1 && fm.fileExists(atPath: firstURL.path, isDirectory: &isDir) && isDir.boolValue {
                // User picked a directory of pad files
                let packName = firstURL.lastPathComponent
                let dest = self.customPadsDirectory.appendingPathComponent(packName)
                try? fm.removeItem(at: dest)
                try? fm.copyItem(at: firstURL, to: dest)
                
                self.reloadPacks()
                self.activePackId = dest.path
                completion(true)
            } else {
                // User picked multiple audio files
                let packName = "Custom Pad \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-"))"
                let dest = self.customPadsDirectory.appendingPathComponent(packName)
                try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
                
                for url in panel.urls {
                    let target = dest.appendingPathComponent(url.lastPathComponent)
                    try? fm.copyItem(at: url, to: target)
                }
                
                self.reloadPacks()
                self.activePackId = dest.path
                completion(true)
            }
        }
    }
    
    public func getPadBuffer(for key: String, packId: String? = nil, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let chosenId = packId ?? activePackId
        let pack = availablePacks.first(where: { $0.id == chosenId }) ?? activePack
        let normKey = AudioSampleBank.normalizeKeyForPad(key)
        
        if pack.isBundled || pack.folderPath == nil {
            return AudioSampleBank.shared.getPadSample(for: normKey, packId: pack.id, format: format)
        }
        
        guard let folderPath = pack.folderPath else {
            return AudioSampleBank.shared.getPadSample(for: normKey, packId: "simple", format: format)
        }
        
        let fm = FileManager.default
        let folderURL = URL(fileURLWithPath: folderPath)
        
        guard let files = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return AudioSampleBank.shared.getPadSample(for: normKey, packId: "simple", format: format)
        }
        
        // Find best match for key
        let targetLower = normKey.lowercased()
        for file in files {
            let fname = file.deletingPathExtension().lastPathComponent.lowercased()
            // Check exact key tokens: e.g. "c full mix", "pad c", "key_c", "c.wav"
            let tokens = fname.components(separatedBy: CharacterSet(charactersIn: " _-."))
            if tokens.contains(targetLower) || fname.hasPrefix("\(targetLower) ") || fname.hasPrefix("\(targetLower)_") || fname == targetLower {
                if let buf = AudioSampleBank.shared.loadAndConvertBuffer(at: file, targetFormat: format) {
                    return AudioSampleBank.normalizePadBufferRMS(buf)
                }
            }
        }
        
        // Fallback to bundled Simple pad if key not found in custom pack
        return AudioSampleBank.shared.getPadSample(for: normKey, packId: "simple", format: format)
    }
}
