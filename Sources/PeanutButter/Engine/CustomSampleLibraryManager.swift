import Foundation
import AVFoundation
import Accelerate
import AppKit

/// Metadata representing a user-uploaded custom click sample pack
public struct CustomClickPack: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var folderPath: String
    public var accentFile: String?
    public var quarterFile: String?
    public var eighthFile: String?
    public var sixteenthFile: String?
    public var isCloud: Bool
    
    public var folderURL: URL {
        URL(fileURLWithPath: folderPath, isDirectory: true)
    }
    
    public var clickSoundType: ClickSoundType {
        .custom(packId: id)
    }
    
    public var assignedSubdivisionCount: Int {
        [accentFile, quarterFile, eighthFile, sixteenthFile].compactMap { $0 }.count
    }
    
    public var hasAnyAudio: Bool {
        assignedSubdivisionCount > 0
    }
    
    public func assignedFile(for subdivision: ClickSubdivision) -> String? {
        switch subdivision {
        case .accent: return accentFile
        case .quarter: return quarterFile
        case .eighth: return eighthFile
        case .sixteenth: return sixteenthFile
        }
    }
    
    /// Resolves the best matching audio URL for a subdivision with clean fallback when fewer than 4 files are uploaded
    public func resolvedURL(for subdivision: ClickSubdivision) -> URL? {
        let candidate: String?
        switch subdivision {
        case .accent:
            candidate = accentFile ?? quarterFile ?? eighthFile ?? sixteenthFile
        case .quarter:
            candidate = quarterFile ?? accentFile ?? eighthFile ?? sixteenthFile
        case .eighth:
            candidate = eighthFile ?? quarterFile ?? accentFile ?? sixteenthFile
        case .sixteenth:
            candidate = sixteenthFile ?? eighthFile ?? quarterFile ?? accentFile
        }
        guard let filename = candidate, !filename.isEmpty else { return nil }
        let url = folderURL.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Controls where an unrecognized user-uploaded custom guide cue is surfaced in menus
public enum CustomGuideCueKind: String, Codable, CaseIterable, Sendable {
    case directional = "directional"
    case songSection = "section"

    public var displayName: String {
        switch self {
        case .directional: return "Directional Cue"
        case .songSection: return "Song Section"
        }
    }

    public var shortLabel: String {
        switch self {
        case .directional: return "Directional"
        case .songSection: return "Section"
        }
    }
}

/// Metadata representing a user-uploaded custom spoken guide voice sample pack
public struct CustomGuidePack: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var folderPath: String
    /// Map of normalized phrase key (e.g. "chorus 1", "1", "all in") -> relative audio filename
    public var phraseFiles: [String: String]
    public var isCloud: Bool
    public var isBundled: Bool = false
    /// Classification overrides for non-standard user-uploaded guide cues (.directional vs .songSection)
    public var customCueKinds: [String: CustomGuideCueKind] = [:]
    /// Preserved display casing for custom guide cues (e.g. "Horns In", "Altar Call")
    public var customCueLabels: [String: String] = [:]

    public init(
        id: String,
        name: String,
        folderPath: String,
        phraseFiles: [String: String],
        isCloud: Bool,
        isBundled: Bool = false,
        customCueKinds: [String: CustomGuideCueKind] = [:],
        customCueLabels: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.folderPath = folderPath
        self.phraseFiles = phraseFiles
        self.isCloud = isCloud
        self.isBundled = isBundled
        self.customCueKinds = customCueKinds
        self.customCueLabels = customCueLabels
    }
    
    public var folderURL: URL {
        URL(fileURLWithPath: folderPath, isDirectory: true)
    }
    
    public var guideVoice: GuideVoice {
        .custom(packId: id)
    }
    
    public var phraseCount: Int {
        phraseFiles.count
    }
    
    public func fileURL(forNormalizedPhrase key: String) -> URL? {
        guard let filename = phraseFiles[key], !filename.isEmpty else { return nil }
        let url = folderURL.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func displayLabel(forNormalizedPhrase key: String) -> String {
        if let saved = customCueLabels[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            return saved
        }
        return CustomSampleLibraryManager.formatPhraseDisplayLabel(key)
    }

    public func cueKind(forNormalizedPhrase key: String) -> CustomGuideCueKind {
        if let explicit = customCueKinds[key] {
            return explicit
        }
        return CustomSampleLibraryManager.inferDefaultCueKind(forNormalizedPhrase: key)
    }
}

/// Categorized standard cue list shown in the Custom Guide Sample Manager
public struct StandardGuideCueCategory: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let phrases: [String]
}

private struct CustomClickPackManifest: Codable {
    var id: String
    var name: String
    var accentFile: String?
    var quarterFile: String?
    var eighthFile: String?
    var sixteenthFile: String?
}

private struct CustomGuidePackManifest: Codable {
    var id: String
    var name: String
    var phraseFiles: [String: String]
    var customCueKinds: [String: CustomGuideCueKind]?
    var customCueLabels: [String: String]?
}

/// Manages default Click Sound / Guide Voice preferences and user-uploaded custom Click & Guide sample packs.
public final class CustomSampleLibraryManager: ObservableObject, @unchecked Sendable {
    public static let shared = CustomSampleLibraryManager()
    
    public static let defaultClickSoundKey = "Playback_DefaultClickSound"
    public static let defaultGuideVoiceKey = "Playback_DefaultGuideVoice"
    public static let defaultGuideFallbackVoiceKey = "Playback_DefaultGuideFallbackVoice"
    
    public static let supportedAudioExtensions: Set<String> = [
        "wav", "aif", "aiff", "m4a", "mp3", "caf", "flac"
    ]

    public static let standardCountInCues: [String] = ["1", "2", "3", "4", "5", "6", "7", "8"]

    public static let standardSongSectionCues: [String] = [
        "Intro", "Verse", "Verse 1", "Verse 2", "Verse 3", "Verse 4", "Verse 5", "Verse 6",
        "Pre Chorus", "Pre Chorus 1", "Pre Chorus 2", "Pre Chorus 3", "Pre Chorus 4",
        "Chorus", "Chorus 1", "Chorus 2", "Chorus 3", "Chorus 4", "Post Chorus",
        "Bridge", "Bridge 1", "Bridge 2", "Bridge 3", "Bridge 4", "Bridge 5",
        "Instrumental", "Interlude", "Vamp", "Tag", "Turnaround",
        "Breakdown", "Solo", "Acapella", "Refrain", "Passage", "Rap", "Exhortation",
        "Outro", "Ending"
    ]

    public static let standardDirectionalCues: [String] = [
        "Ad Lib", "All In", "All Out", "Band In", "Band Out",
        "Bass", "Big", "Big Ending", "Break", "Bring It Down",
        "Build", "Drop", "Drums", "Drums Build", "Drums In",
        "Drums Out", "Fade Out", "Guitars", "Hits", "Hold",
        "Key Change Down", "Key Change Up", "Keys", "Last Time", "Repeat",
        "Slowly Build", "Softly", "Stop", "Swell", "Vocals Only",
        "Worship Freely"
    ]

    /// All 33 studio-recorded directional cues bundled with PeanutButter (31 pure directional + Acapella & Breakdown)
    public static let includedDirectionalMenuOptions: [String] = (
        standardDirectionalCues + ["Acapella", "Breakdown"]
    ).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    
    public static let standardGuideCueCategories: [StandardGuideCueCategory] = [
        StandardGuideCueCategory(
            id: "countin",
            title: "Count-In",
            phrases: standardCountInCues
        ),
        StandardGuideCueCategory(
            id: "sections",
            title: "Song Sections",
            phrases: standardSongSectionCues
        ),
        StandardGuideCueCategory(
            id: "dynamic",
            title: "Directional & Dynamic Cues",
            phrases: standardDirectionalCues
        )
    ]

    public static let standardCountInNormalizedKeys: Set<String> = {
        var keys = Set(standardCountInCues.map { AudioSampleBank.shared.normalizePhraseKey($0) })
        keys.insert("count in")
        keys.insert("count off")
        return keys
    }()

    public static let standardSectionNormalizedKeys: Set<String> = Set(
        standardSongSectionCues.map { AudioSampleBank.shared.normalizePhraseKey($0) }
    )

    public static let standardDirectionalNormalizedKeys: Set<String> = Set(
        standardDirectionalCues.map { AudioSampleBank.shared.normalizePhraseKey($0) }
    )

    public static let standardNormalizedKeys: Set<String> = standardCountInNormalizedKeys
        .union(standardSectionNormalizedKeys)
        .union(standardDirectionalNormalizedKeys)

    public static func isStandardRecognizedGuidePhrase(_ rawPhrase: String) -> Bool {
        recognizedStandardCategoryTitle(forPhrase: rawPhrase) != nil
    }

    public static func recognizedStandardCategoryTitle(forPhrase rawPhrase: String) -> String? {
        let key = AudioSampleBank.shared.normalizePhraseKey(rawPhrase)
        guard !key.isEmpty else { return nil }
        if standardCountInNormalizedKeys.contains(key) {
            return "Count-In"
        }
        if standardDirectionalNormalizedKeys.contains(key) {
            return "Directional Cue"
        }
        if standardSectionNormalizedKeys.contains(key) {
            return "Song Section"
        }
        return nil
    }

    public static func inferDefaultCueKind(forNormalizedPhrase key: String) -> CustomGuideCueKind {
        let norm = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !norm.isEmpty else { return .directional }
        let words = Set(norm.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        let sectionKeywords: Set<String> = [
            "intro", "verse", "chorus", "pre", "post", "bridge",
            "instrumental", "interlude", "vamp", "tag", "turnaround",
            "solo", "refrain", "passage", "rap", "exhortation",
            "outro", "ending", "spontaneous", "altar", "ministry", "selah"
        ]
        if !words.isDisjoint(with: sectionKeywords) {
            return .songSection
        }
        return .directional
    }

    public static func formatPhraseDisplayLabel(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        let collapsed = cleaned.split(whereSeparator: { $0.isWhitespace }).map(String.init).joined(separator: " ")
        if collapsed == collapsed.lowercased() {
            return collapsed
                .split(separator: " ")
                .map { word in
                    guard let first = word.first else { return "" }
                    return String(first).uppercased() + word.dropFirst()
                }
                .joined(separator: " ")
        }
        return collapsed
    }

    public static func cleanDisplayLabel(fromFilename filename: String, fallbackKey: String) -> String {
        var stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let dashRange = stem.range(of: " - ") {
            let suffix = String(stem[dashRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !suffix.isEmpty {
                stem = suffix
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"^\d+[\s._-]+([A-Za-z].*)$"#) {
            let ns = stem as NSString
            if let match = regex.firstMatch(in: stem, range: NSRange(location: 0, length: ns.length)),
               match.numberOfRanges > 1 {
                stem = ns.substring(with: match.range(at: 1))
            }
        }
        stem = stem.replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
        if stem.isEmpty || stem == stem.lowercased() {
            return formatPhraseDisplayLabel(stem.isEmpty ? fallbackKey : stem)
        }
        return stem
    }
    
    @Published public private(set) var customClickPacks: [CustomClickPack] = []
    @Published public private(set) var customGuidePacks: [CustomGuidePack] = []

    public var includedGuidePacks: [CustomGuidePack] {
        customGuidePacks.filter { $0.isBundled }
    }

    public var userCustomGuidePacks: [CustomGuidePack] {
        customGuidePacks.filter { !$0.isBundled }
    }
    @Published public var defaultClickSoundRaw: String = ""
    @Published public var defaultGuideVoiceRaw: String = ""
    @Published public var defaultGuideFallbackVoiceRaw: String = GuideVoice.zoe.rawValue
    
    private let lock = NSLock()
    private var clickPackIndex: [String: CustomClickPack] = [:]
    private var guidePackIndex: [String: CustomGuidePack] = [:]
    private var previewPlayer: AVAudioPlayer?
    
    public let localClickSamplesDirectory: URL
    public let localGuideSamplesDirectory: URL
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let rootDir = appSupport.appendingPathComponent("PeanutButter", isDirectory: true)
        self.localClickSamplesDirectory = rootDir.appendingPathComponent("ClickSamples", isDirectory: true)
        self.localGuideSamplesDirectory = rootDir.appendingPathComponent("GuideSamples", isDirectory: true)
        
        try? FileManager.default.createDirectory(at: localClickSamplesDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: localGuideSamplesDirectory, withIntermediateDirectories: true)
        
        let savedClick = UserDefaults.standard.string(forKey: Self.defaultClickSoundKey) ?? ""
        let savedGuide = UserDefaults.standard.string(forKey: Self.defaultGuideVoiceKey) ?? ""
        let savedFallback = UserDefaults.standard.string(forKey: Self.defaultGuideFallbackVoiceKey) ?? GuideVoice.zoe.rawValue
        
        self.defaultClickSoundRaw = savedClick
        self.defaultGuideVoiceRaw = savedGuide
        self.defaultGuideFallbackVoiceRaw = savedFallback
        
        refreshPacks()
    }
    
    // MARK: - Default Preferences
    
    public var defaultClickSound: ClickSoundType {
        get {
            let stored = lock.withLock { defaultClickSoundRaw }
            if !stored.isEmpty {
                let candidate = ClickSoundType(rawValue: stored)
                if let customId = candidate.customPackId {
                    if clickPack(forId: customId) != nil {
                        return candidate
                    }
                } else if !candidate.isSampled || AudioSampleBank.shared.hasSampledClicks {
                    return candidate
                } else {
                    return candidate
                }
            }
            return .beep
        }
        set {
            setDefaultClickSound(newValue)
        }
    }
    
    public func setDefaultClickSound(_ sound: ClickSoundType) {
        lock.withLock {
            defaultClickSoundRaw = sound.rawValue
        }
        UserDefaults.standard.set(sound.rawValue, forKey: Self.defaultClickSoundKey)
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.defaultClickSoundRaw = sound.rawValue
            }
        }
    }
    
    /// Ordered list of bundled custom guide packs, preferred in order, used when the user
    /// has never explicitly chosen a guide voice. The first pack that is actually present
    /// wins, so installs missing one pack still resolve to a sensible voice.
    private static let bundledGuidePackPreferenceOrder: [String] = [
        "sam-male",
        "caleb-male"
    ]
    
    public var defaultGuideVoice: GuideVoice {
        get {
            let stored = lock.withLock { defaultGuideVoiceRaw }
            if !stored.isEmpty {
                let candidate = GuideVoice(rawValue: stored)
                if let customId = candidate.customPackId {
                    if guidePack(forId: customId) != nil {
                        return candidate
                    }
                } else {
                    return candidate
                }
            }
            for packId in Self.bundledGuidePackPreferenceOrder where guidePack(forId: packId) != nil {
                return GuideVoice.custom(packId: packId)
            }
            return .rita
        }
        set {
            setDefaultGuideVoice(newValue)
        }
    }
    
    public func setDefaultGuideVoice(_ voice: GuideVoice) {
        lock.withLock {
            defaultGuideVoiceRaw = voice.rawValue
        }
        UserDefaults.standard.set(voice.rawValue, forKey: Self.defaultGuideVoiceKey)
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.defaultGuideVoiceRaw = voice.rawValue
            }
        }
    }
    
    public var defaultGuideFallbackVoice: GuideVoice {
        get {
            let stored = lock.withLock { defaultGuideFallbackVoiceRaw }
            return stored.isEmpty ? .zoe : GuideVoice(rawValue: stored)
        }
        set {
            lock.withLock {
                defaultGuideFallbackVoiceRaw = newValue.rawValue
            }
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.defaultGuideFallbackVoiceKey)
        }
    }
    
    // MARK: - Pack Scanning
    
    public func refreshPacks() {
        var loadedClicks: [CustomClickPack] = []
        var loadedGuides: [CustomGuidePack] = []
        
        loadedClicks.append(contentsOf: scanClickDirectory(localClickSamplesDirectory, isCloud: false))
        if let cloudClicks = LibraryBrowserManager.cloudClicksDirectoryURL {
            let existingIds = Set(loadedClicks.map { $0.id })
            for pack in scanClickDirectory(cloudClicks, isCloud: true) where !existingIds.contains(pack.id) {
                loadedClicks.append(pack)
            }
        }
        loadedClicks.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        
        loadedGuides.append(contentsOf: scanGuideDirectory(localGuideSamplesDirectory, isCloud: false, isBundled: false))
        var bundledDirs: [URL] = []
        if let resURL = Bundle.main.resourceURL {
            bundledDirs.append(resURL.appendingPathComponent("Audio/Guides", isDirectory: true))
        }
        bundledDirs.append(URL(fileURLWithPath: "Sources/PeanutButter/Resources/Audio/Guides", isDirectory: true))
        var bundledPackIds: Set<String> = []
        for bDir in bundledDirs {
            let bundledPacks = scanGuideDirectory(bDir, isCloud: false, isBundled: true)
            for p in bundledPacks {
                bundledPackIds.insert(p.id)
            }
            let existingGuideIds = Set(loadedGuides.map { $0.id })
            for pack in bundledPacks where !existingGuideIds.contains(pack.id) {
                loadedGuides.append(pack)
            }
        }
        for i in 0..<loadedGuides.count where bundledPackIds.contains(loadedGuides[i].id) {
            loadedGuides[i].isBundled = true
        }
        if let cloudGuides = LibraryBrowserManager.cloudGuidesDirectoryURL {
            let existingIds = Set(loadedGuides.map { $0.id })
            for pack in scanGuideDirectory(cloudGuides, isCloud: true, isBundled: false) where !existingIds.contains(pack.id) {
                loadedGuides.append(pack)
            }
        }
        loadedGuides.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        
        lock.withLock {
            clickPackIndex = Dictionary(uniqueKeysWithValues: loadedClicks.map { ($0.id, $0) })
            guidePackIndex = Dictionary(uniqueKeysWithValues: loadedGuides.map { ($0.id, $0) })
        }
        
        if Thread.isMainThread {
            self.customClickPacks = loadedClicks
            self.customGuidePacks = loadedGuides
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.customClickPacks = loadedClicks
                self?.customGuidePacks = loadedGuides
            }
        }
    }
    
    public func clickPack(forId id: String) -> CustomClickPack? {
        lock.withLock { clickPackIndex[id] }
    }
    
    public func guidePack(forId id: String) -> CustomGuidePack? {
        lock.withLock { guidePackIndex[id] }
    }
    
    private func scanClickDirectory(_ root: URL, isCloud: Bool) -> [CustomClickPack] {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        var packs: [CustomClickPack] = []
        for dir in subdirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            
            let manifestURL = dir.appendingPathComponent("pack.json")
            if let data = try? Data(contentsOf: manifestURL),
               let manifest = try? JSONDecoder().decode(CustomClickPackManifest.self, from: data) {
                let pack = CustomClickPack(
                    id: manifest.id,
                    name: manifest.name,
                    folderPath: dir.path,
                    accentFile: manifest.accentFile,
                    quarterFile: manifest.quarterFile,
                    eighthFile: manifest.eighthFile,
                    sixteenthFile: manifest.sixteenthFile,
                    isCloud: isCloud
                )
                packs.append(pack)
            } else {
                // Auto-detect files inside unmanaged directory (e.g. dropped directly into Cloud ClickSamples folder)
                let files = audioFiles(in: dir)
                guard !files.isEmpty else { continue }
                let mapped = autoMapClickFiles(files)
                let id = sanitizePackId(dir.lastPathComponent)
                let pack = CustomClickPack(
                    id: id,
                    name: dir.lastPathComponent,
                    folderPath: dir.path,
                    accentFile: mapped[.accent]?.lastPathComponent,
                    quarterFile: mapped[.quarter]?.lastPathComponent,
                    eighthFile: mapped[.eighth]?.lastPathComponent,
                    sixteenthFile: mapped[.sixteenth]?.lastPathComponent,
                    isCloud: isCloud
                )
                packs.append(pack)
            }
        }
        return packs
    }
    
    private func scanGuideDirectory(_ root: URL, isCloud: Bool, isBundled: Bool = false) -> [CustomGuidePack] {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        var packs: [CustomGuidePack] = []
        for dir in subdirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            
            let manifestURL = dir.appendingPathComponent("pack.json")
            if let data = try? Data(contentsOf: manifestURL),
               let manifest = try? JSONDecoder().decode(CustomGuidePackManifest.self, from: data) {
                let pack = CustomGuidePack(
                    id: manifest.id,
                    name: manifest.name,
                    folderPath: dir.path,
                    phraseFiles: manifest.phraseFiles,
                    isCloud: isCloud,
                    isBundled: isBundled,
                    customCueKinds: manifest.customCueKinds ?? [:],
                    customCueLabels: manifest.customCueLabels ?? [:]
                )
                packs.append(pack)
            } else {
                let files = audioFiles(in: dir)
                guard !files.isEmpty else { continue }
                var phraseFiles: [String: String] = [:]
                var customKinds: [String: CustomGuideCueKind] = [:]
                var customLabels: [String: String] = [:]
                for file in files {
                    let key = detectGuidePhraseKey(fromFilename: file.lastPathComponent)
                    if !key.isEmpty && phraseFiles[key] == nil {
                        phraseFiles[key] = file.lastPathComponent
                        if !Self.standardNormalizedKeys.contains(key) {
                            customKinds[key] = Self.inferDefaultCueKind(forNormalizedPhrase: key)
                            customLabels[key] = Self.cleanDisplayLabel(fromFilename: file.lastPathComponent, fallbackKey: key)
                        }
                    }
                }
                guard !phraseFiles.isEmpty else { continue }
                let pack = CustomGuidePack(
                    id: sanitizePackId(dir.lastPathComponent),
                    name: dir.lastPathComponent,
                    folderPath: dir.path,
                    phraseFiles: phraseFiles,
                    isCloud: isCloud,
                    isBundled: isBundled,
                    customCueKinds: customKinds,
                    customCueLabels: customLabels
                )
                packs.append(pack)
            }
        }
        return packs
    }
    
    // MARK: - Click Pack CRUD & Import
    
    @discardableResult
    public func createCustomClickPack(name: String) -> CustomClickPack {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let packName = trimmed.isEmpty ? "Custom Click \(customClickPacks.count + 1)" : trimmed
        let packId = makeUniqueClickPackId(base: packName)
        let folder = localClickSamplesDirectory.appendingPathComponent(packId, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        
        let pack = CustomClickPack(
            id: packId,
            name: packName,
            folderPath: folder.path,
            accentFile: nil,
            quarterFile: nil,
            eighthFile: nil,
            sixteenthFile: nil,
            isCloud: false
        )
        writeClickManifest(pack)
        refreshPacks()
        return clickPack(forId: packId) ?? pack
    }
    
    @discardableResult
    public func importCustomClickPack(from selectedURLs: [URL], preferredName: String? = nil) -> CustomClickPack? {
        guard !selectedURLs.isEmpty else { return nil }
        let fm = FileManager.default
        
        var collectedFiles: [URL] = []
        var derivedName = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        for url in selectedURLs {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if derivedName.isEmpty {
                    derivedName = url.lastPathComponent
                }
                collectedFiles.append(contentsOf: audioFiles(in: url, recursive: true))
            } else if Self.supportedAudioExtensions.contains(url.pathExtension.lowercased()) {
                collectedFiles.append(url)
            }
        }
        
        guard !collectedFiles.isEmpty else { return nil }
        
        if derivedName.isEmpty {
            let base = collectedFiles[0].deletingPathExtension().lastPathComponent
            derivedName = Self.cleanClickPackBaseName(base)
            if derivedName.isEmpty { derivedName = "Custom Click" }
        }
        
        let pack = createCustomClickPack(name: derivedName)
        let folder = pack.folderURL
        let mapped = autoMapClickFiles(collectedFiles)
        
        var updated = pack
        for (subdivision, srcURL) in mapped {
            let destName = "\(subdivision.rawValue.lowercased())_\(srcURL.lastPathComponent)"
            let destURL = folder.appendingPathComponent(destName)
            try? fm.removeItem(at: destURL)
            if (try? fm.copyItem(at: srcURL, to: destURL)) != nil {
                AudioSampleBank.shared.invalidateCachedBuffers(matchingPathPrefix: destURL.path)
                switch subdivision {
                case .accent: updated.accentFile = destName
                case .quarter: updated.quarterFile = destName
                case .eighth: updated.eighthFile = destName
                case .sixteenth: updated.sixteenthFile = destName
                }
            }
        }
        
        writeClickManifest(updated)
        refreshPacks()
        return clickPack(forId: pack.id) ?? updated
    }
    
    @discardableResult
    public func setClickSubdivisionFile(packId: String, subdivision: ClickSubdivision, sourceURL: URL?) -> Bool {
        guard var pack = clickPack(forId: packId) else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: pack.folderURL, withIntermediateDirectories: true)
        
        if let oldFile = pack.assignedFile(for: subdivision) {
            let oldURL = pack.folderURL.appendingPathComponent(oldFile)
            AudioSampleBank.shared.invalidateCachedBuffers(matchingPathPrefix: oldURL.path)
            try? fm.removeItem(at: oldURL)
        }
        
        let newFilename: String?
        if let src = sourceURL {
            let destName = "\(subdivision.rawValue.lowercased())_\(src.lastPathComponent)"
            let destURL = pack.folderURL.appendingPathComponent(destName)
            try? fm.removeItem(at: destURL)
            guard (try? fm.copyItem(at: src, to: destURL)) != nil else { return false }
            AudioSampleBank.shared.invalidateCachedBuffers(matchingPathPrefix: destURL.path)
            newFilename = destName
        } else {
            newFilename = nil
        }
        
        switch subdivision {
        case .accent: pack.accentFile = newFilename
        case .quarter: pack.quarterFile = newFilename
        case .eighth: pack.eighthFile = newFilename
        case .sixteenth: pack.sixteenthFile = newFilename
        }
        
        writeClickManifest(pack)
        refreshPacks()
        return true
    }
    
    public func renameClickPack(id: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var pack = clickPack(forId: id) else { return }
        pack.name = trimmed
        writeClickManifest(pack)
        refreshPacks()
    }
    
    public func deleteClickPack(id: String) {
        guard let pack = clickPack(forId: id) else { return }
        AudioSampleBank.shared.invalidateCachedBuffers(matchingPathPrefix: pack.folderPath)
        try? FileManager.default.removeItem(at: pack.folderURL)
        if defaultClickSound.customPackId == id {
            let fallback: ClickSoundType = .beep
            setDefaultClickSound(fallback)
        }
        refreshPacks()
    }
    
    // MARK: - Guide Pack CRUD & Import
    
    @discardableResult
    public func createCustomGuidePack(name: String) -> CustomGuidePack {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let packName = trimmed.isEmpty ? "Custom Guide \(customGuidePacks.count + 1)" : trimmed
        let packId = makeUniqueGuidePackId(base: packName)
        let folder = localGuideSamplesDirectory.appendingPathComponent(packId, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        
        let pack = CustomGuidePack(
            id: packId,
            name: packName,
            folderPath: folder.path,
            phraseFiles: [:],
            isCloud: false
        )
        writeGuideManifest(pack)
        refreshPacks()
        return guidePack(forId: packId) ?? pack
    }
    
    @discardableResult
    public func importCustomGuidePack(from selectedURLs: [URL], preferredName: String? = nil) -> CustomGuidePack? {
        guard !selectedURLs.isEmpty else { return nil }
        var derivedName = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if derivedName.isEmpty {
            let first = selectedURLs[0]
            let isDir = (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            derivedName = isDir ? first.lastPathComponent : "Custom Guide \(customGuidePacks.count + 1)"
        }
        
        let pack = createCustomGuidePack(name: derivedName)
        _ = importGuideFiles(selectedURLs, intoPackId: pack.id)
        return guidePack(forId: pack.id)
    }
    
    @discardableResult
    public func importGuideFiles(_ selectedURLs: [URL], intoPackId packId: String) -> Int {
        guard var pack = guidePack(forId: packId) else { return 0 }
        let fm = FileManager.default
        try? fm.createDirectory(at: pack.folderURL, withIntermediateDirectories: true)
        
        var collectedFiles: [URL] = []
        for url in selectedURLs {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                collectedFiles.append(contentsOf: audioFiles(in: url, recursive: true))
            } else if Self.supportedAudioExtensions.contains(url.pathExtension.lowercased()) {
                collectedFiles.append(url)
            }
        }
        
        var importedCount = 0
        for srcURL in collectedFiles {
            let key = detectGuidePhraseKey(fromFilename: srcURL.lastPathComponent)
            guard !key.isEmpty else { continue }
            
            if let existing = pack.phraseFiles[key] {
                let oldURL = pack.folderURL.appendingPathComponent(existing)
                AudioSampleBank.shared.invalidateCachedBuffers(matchingPathPrefix: oldURL.path)
                try? fm.removeItem(at: oldURL)
            }
            
            let safeKey = key.replacingOccurrences(of: " ", with: "_")
            let ext = srcURL.pathExtension.isEmpty ? "wav" : srcURL.pathExtension
            let destName = "\(safeKey).\(ext)"
            let destURL = pack.folderURL.appendingPathComponent(destName)
            try? fm.removeItem(at: destURL)
            if (try? fm.copyItem(at: srcURL, to: destURL)) != nil {
                AudioSampleBank.shared.invalidateCachedBuffers(matchingPathPrefix: destURL.path)
                pack.phraseFiles[key] = destName
                if Self.standardNormalizedKeys.contains(key) {
                    pack.customCueKinds.removeValue(forKey: key)
                    pack.customCueLabels.removeValue(forKey: key)
                } else {
                    if pack.customCueKinds[key] == nil {
                        pack.customCueKinds[key] = Self.inferDefaultCueKind(forNormalizedPhrase: key)
                    }
                    pack.customCueLabels[key] = Self.cleanDisplayLabel(fromFilename: srcURL.lastPathComponent, fallbackKey: key)
                }
                importedCount += 1
            }
        }
        
        writeGuideManifest(pack)
        refreshPacks()
        return importedCount
    }
    
    @discardableResult
    public func setGuidePhraseFile(
        packId: String,
        phrase: String,
        sourceURL: URL?,
        cueKind: CustomGuideCueKind? = nil
    ) -> Bool {
        guard var pack = guidePack(forId: packId) else { return false }
        let key = AudioSampleBank.shared.normalizePhraseKey(phrase)
        guard !key.isEmpty else { return false }
        
        let fm = FileManager.default
        try? fm.createDirectory(at: pack.folderURL, withIntermediateDirectories: true)
        
        if let existing = pack.phraseFiles[key] {
            let oldURL = pack.folderURL.appendingPathComponent(existing)
            AudioSampleBank.shared.invalidateCachedBuffers(matchingPathPrefix: oldURL.path)
            try? fm.removeItem(at: oldURL)
        }
        
        if let src = sourceURL {
            let safeKey = key.replacingOccurrences(of: " ", with: "_")
            let ext = src.pathExtension.isEmpty ? "wav" : src.pathExtension
            let destName = "\(safeKey).\(ext)"
            let destURL = pack.folderURL.appendingPathComponent(destName)
            try? fm.removeItem(at: destURL)
            guard (try? fm.copyItem(at: src, to: destURL)) != nil else { return false }
            AudioSampleBank.shared.invalidateCachedBuffers(matchingPathPrefix: destURL.path)
            pack.phraseFiles[key] = destName
            if Self.standardNormalizedKeys.contains(key) {
                pack.customCueKinds.removeValue(forKey: key)
                pack.customCueLabels.removeValue(forKey: key)
            } else {
                pack.customCueKinds[key] = cueKind ?? pack.customCueKinds[key] ?? Self.inferDefaultCueKind(forNormalizedPhrase: key)
                let formatted = Self.formatPhraseDisplayLabel(phrase)
                if !formatted.isEmpty {
                    pack.customCueLabels[key] = formatted
                }
            }
        } else {
            pack.phraseFiles.removeValue(forKey: key)
            pack.customCueKinds.removeValue(forKey: key)
            pack.customCueLabels.removeValue(forKey: key)
        }
        
        writeGuideManifest(pack)
        refreshPacks()
        return true
    }

    public func setCustomGuideCueKind(packId: String, phraseKey: String, kind: CustomGuideCueKind) {
        guard var pack = guidePack(forId: packId) else { return }
        let key = AudioSampleBank.shared.normalizePhraseKey(phraseKey)
        guard !key.isEmpty, pack.phraseFiles[key] != nil else { return }
        pack.customCueKinds[key] = kind
        writeGuideManifest(pack)
        refreshPacks()
    }

    /// Returns deduplicated custom guide cue labels of the requested kind from all user custom guide packs,
    /// prioritizing the currently active / default custom guide pack first.
    public func userCustomCueOptions(ofKind kind: CustomGuideCueKind, preferredVoice: GuideVoice? = nil) -> [String] {
        let packs = userCustomGuidePacks
        var orderedPacks: [CustomGuidePack] = []
        var addedPackIds = Set<String>()
        for candidateId in [preferredVoice?.customPackId, defaultGuideVoice.customPackId].compactMap({ $0 }) {
            if !addedPackIds.contains(candidateId), let match = packs.first(where: { $0.id == candidateId }) {
                orderedPacks.append(match)
                addedPackIds.insert(candidateId)
            }
        }
        for pack in packs where !addedPackIds.contains(pack.id) {
            orderedPacks.append(pack)
            addedPackIds.insert(pack.id)
        }

        var seenLower = Set<String>()
        var result: [String] = []
        for pack in orderedPacks {
            let labels = pack.phraseFiles.keys
                .filter { !Self.standardNormalizedKeys.contains($0) && pack.cueKind(forNormalizedPhrase: $0) == kind }
                .map { pack.displayLabel(forNormalizedPhrase: $0) }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            for label in labels {
                let lower = label.lowercased()
                if !seenLower.contains(lower) {
                    seenLower.insert(lower)
                    result.append(label)
                }
            }
        }
        return result
    }
    
    public func renameGuidePack(id: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var pack = guidePack(forId: id) else { return }
        pack.name = trimmed
        writeGuideManifest(pack)
        refreshPacks()
    }
    
    public func deleteGuidePack(id: String) {
        guard let pack = guidePack(forId: id) else { return }
        AudioSampleBank.shared.invalidateCachedBuffers(matchingPathPrefix: pack.folderPath)
        try? FileManager.default.removeItem(at: pack.folderURL)
        if defaultGuideVoice.customPackId == id {
            setDefaultGuideVoice(.rita)
        }
        refreshPacks()
    }
    
    // MARK: - Sample Buffer Resolution
    
    public func getClickSample(
        packId: String,
        subdivision: ClickSubdivision,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let pack = clickPack(forId: packId),
              let url = pack.resolvedURL(for: subdivision),
              let rawBuffer = AudioSampleBank.shared.loadAndConvertBuffer(at: url, targetFormat: format) else {
            return nil
        }
        return normalizeClickSampleIfNeeded(rawBuffer)
    }
    
    public func getGuidePhraseSample(
        phrase: String,
        packId: String,
        targetFormat: AVAudioFormat
    ) -> SpokenPhraseData? {
        guard let pack = guidePack(forId: packId) else { return nil }
        let normalized = AudioSampleBank.shared.normalizePhraseKey(phrase)
        guard let url = pack.fileURL(forNormalizedPhrase: normalized) else {
            return nil
        }
        return AudioSampleBank.shared.loadCustomPhraseData(at: url, targetFormat: targetFormat)
    }

    public func getAnyUserCustomPhraseSample(
        phrase: String,
        targetFormat: AVAudioFormat
    ) -> SpokenPhraseData? {
        let normalized = AudioSampleBank.shared.normalizePhraseKey(phrase)
        guard !normalized.isEmpty else { return nil }
        for pack in userCustomGuidePacks {
            if let url = pack.fileURL(forNormalizedPhrase: normalized),
               let data = AudioSampleBank.shared.loadCustomPhraseData(at: url, targetFormat: targetFormat) {
                return data
            }
        }
        return nil
    }
    
    /// Ensures uploaded custom click samples have healthy transient headroom matching built-in studio clicks
    private func normalizeClickSampleIfNeeded(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let frameCount = Int(source.frameLength)
        let chCount = Int(source.format.channelCount)
        guard frameCount > 0, chCount > 0, let srcChannels = source.floatChannelData else { return source }
        
        var maxPeak: Float = 0.0
        for ch in 0..<chCount {
            var chPeak: Float = 0.0
            vDSP_maxmgv(srcChannels[ch], 1, &chPeak, vDSP_Length(frameCount))
            if chPeak > maxPeak { maxPeak = chPeak }
        }
        
        // Leave already well-calibrated samples untouched; normalize very hot or quiet user files onto a copy
        guard maxPeak > 0.002 else { return source }
        let targetPeak: Float = 0.68
        if maxPeak >= 0.45 && maxPeak <= 0.85 {
            return source
        }
        
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameCapacity),
              let dstChannels = copy.floatChannelData else {
            return source
        }
        copy.frameLength = source.frameLength
        var gain = min(6.0, targetPeak / maxPeak)
        for ch in 0..<chCount {
            vDSP_vsmul(srcChannels[ch], 1, &gain, dstChannels[ch], 1, vDSP_Length(frameCount))
        }
        return copy
    }
    
    // MARK: - Audition Preview
    
    public func previewAudioFile(at url: URL) {
        stopPreview()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.prepareToPlay()
        player.play()
        self.previewPlayer = player
    }
    
    public func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
    }
    
    // MARK: - Open Panels
    
    public func promptImportCustomClickPack(completion: ((CustomClickPack?) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Import Custom Click Samples"
        panel.message = "Select a folder or 1–4 audio files (.wav, .m4a, .mp3, .aiff) for your custom click sound."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .audio]
        
        panel.begin { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else {
                completion?(nil)
                return
            }
            let imported = self?.importCustomClickPack(from: panel.urls)
            completion?(imported)
        }
    }
    
    public func promptAssignClickSubdivision(packId: String, subdivision: ClickSubdivision, completion: ((Bool) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Select \(subdivision.rawValue) Click Sample"
        panel.message = "Choose an audio file (.wav, .m4a, .mp3, .aiff) for the \(subdivision.rawValue.lowercased()) click."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                completion?(false)
                return
            }
            let ok = self?.setClickSubdivisionFile(packId: packId, subdivision: subdivision, sourceURL: url) ?? false
            completion?(ok)
        }
    }
    
    public func promptImportCustomGuidePack(completion: ((CustomGuidePack?) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Import Custom Guide Voice Samples"
        panel.message = "Select a folder or audio files named by cue (e.g. 1.wav, Intro.wav, Chorus.wav, All In.wav)."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .audio]
        
        panel.begin { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else {
                completion?(nil)
                return
            }
            let imported = self?.importCustomGuidePack(from: panel.urls)
            completion?(imported)
        }
    }
    
    public func promptImportGuideFiles(intoPackId packId: String, completion: ((Int) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Import Guide Voice Samples"
        panel.message = "Select audio files or folders named by cue phrase (e.g. 1.wav, Verse 1.wav, Chorus.wav)."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .audio]
        
        panel.begin { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else {
                completion?(0)
                return
            }
            let count = self?.importGuideFiles(panel.urls, intoPackId: packId) ?? 0
            completion?(count)
        }
    }
    
    public func promptAssignGuidePhrase(
        packId: String,
        phrase: String,
        cueKind: CustomGuideCueKind? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        let panel = NSOpenPanel()
        panel.title = "Select Sample for \"\(phrase)\""
        panel.message = "Choose an audio file (.wav, .m4a, .mp3, .aiff) for the \"\(phrase)\" guide cue."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                completion?(false)
                return
            }
            let ok = self?.setGuidePhraseFile(packId: packId, phrase: phrase, sourceURL: url, cueKind: cueKind) ?? false
            completion?(ok)
        }
    }
    
    // MARK: - Auto-Detection & Manifest Helpers
    
    private func autoMapClickFiles(_ files: [URL]) -> [ClickSubdivision: URL] {
        var result: [ClickSubdivision: URL] = [:]
        var unmatched: [URL] = []
        
        for file in files.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            if let detected = detectClickSubdivision(fromFilename: file.lastPathComponent), result[detected] == nil {
                result[detected] = file
            } else {
                unmatched.append(file)
            }
        }
        
        // Assign any unmatched files sequentially into open subdivision slots (Accent -> Quarter -> Eighth -> Sixteenth)
        let order: [ClickSubdivision] = [.accent, .quarter, .eighth, .sixteenth]
        for file in unmatched {
            if let nextSlot = order.first(where: { result[$0] == nil }) {
                result[nextSlot] = file
            }
        }
        return result
    }
    
    private func detectClickSubdivision(fromFilename filename: String) -> ClickSubdivision? {
        let name = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent.lowercased()
        let tokens = name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let tokenSet = Set(tokens)
        
        if tokenSet.contains("accent") || tokenSet.contains("accents") || tokenSet.contains("downbeat")
            || tokenSet.contains("beat1") || tokenSet.contains("hi") || tokenSet.contains("high") {
            return .accent
        }
        if tokenSet.contains("16th") || tokenSet.contains("sixteenth") || tokenSet.contains("sixteenths") || name.contains("16th") {
            return .sixteenth
        }
        if tokenSet.contains("8th") || tokenSet.contains("eighth") || tokenSet.contains("eighths") || name.contains("8th") || tokenSet.contains("sub") {
            return .eighth
        }
        if tokenSet.contains("quarter") || tokenSet.contains("quarters") || tokenSet.contains("4th")
            || tokenSet.contains("main") || tokenSet.contains("lo") || tokenSet.contains("low") || tokenSet.contains("beat") {
            return .quarter
        }
        return nil
    }
    
    public func detectGuidePhraseKey(fromFilename filename: String) -> String {
        var stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Strip common voice/pack prefixes such as "English Female - Chorus 1", "Guide - All In", "01_Intro"
        if let dashRange = stem.range(of: " - ") {
            let suffix = String(stem[dashRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !suffix.isEmpty {
                stem = suffix
            }
        }
        
        if let regex = try? NSRegularExpression(pattern: #"^\d+[\s._-]+([A-Za-z].*)$"#) {
            let ns = stem as NSString
            if let match = regex.firstMatch(in: stem, range: NSRange(location: 0, length: ns.length)),
               match.numberOfRanges > 1 {
                stem = ns.substring(with: match.range(at: 1))
            }
        }
        
        return AudioSampleBank.shared.normalizePhraseKey(stem)
    }
    
    private static func cleanClickPackBaseName(_ raw: String) -> String {
        var cleaned = raw
        for suffix in ["-accents", "-accent", "_accent", " accent", "-quarter", "_quarter", " quarter", "-eighth", "_eighth", " eighth", "-sixteenth", "_sixteenth", " sixteenth"] {
            if cleaned.lowercased().hasSuffix(suffix) {
                cleaned = String(cleaned.dropLast(suffix.count))
                break
            }
        }
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
    }
    
    private func audioFiles(in directory: URL, recursive: Bool = false) -> [URL] {
        let fm = FileManager.default
        if recursive, let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            var found: [URL] = []
            for case let url as URL in enumerator {
                if Self.supportedAudioExtensions.contains(url.pathExtension.lowercased()) {
                    found.append(url)
                }
            }
            return found
        }
        let items = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items.filter { Self.supportedAudioExtensions.contains($0.pathExtension.lowercased()) }
    }
    
    private func writeClickManifest(_ pack: CustomClickPack) {
        let manifest = CustomClickPackManifest(
            id: pack.id,
            name: pack.name,
            accentFile: pack.accentFile,
            quarterFile: pack.quarterFile,
            eighthFile: pack.eighthFile,
            sixteenthFile: pack.sixteenthFile
        )
        let url = pack.folderURL.appendingPathComponent("pack.json")
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: url, options: .atomic)
        }
    }
    
    private func writeGuideManifest(_ pack: CustomGuidePack) {
        let manifest = CustomGuidePackManifest(
            id: pack.id,
            name: pack.name,
            phraseFiles: pack.phraseFiles,
            customCueKinds: pack.customCueKinds.isEmpty ? nil : pack.customCueKinds,
            customCueLabels: pack.customCueLabels.isEmpty ? nil : pack.customCueLabels
        )
        let url = pack.folderURL.appendingPathComponent("pack.json")
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: url, options: .atomic)
        }
    }
    
    private func sanitizePackId(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let allowed = CharacterSet.alphanumerics
        let mapped = lowered.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(mapped)
            .split(separator: "-")
            .joined(separator: "-")
        return collapsed.isEmpty ? UUID().uuidString.prefix(8).lowercased() : collapsed
    }
    
    private func makeUniqueClickPackId(base: String) -> String {
        let slug = sanitizePackId(base)
        let fm = FileManager.default
        var candidate = slug
        var index = 2
        while fm.fileExists(atPath: localClickSamplesDirectory.appendingPathComponent(candidate).path) {
            candidate = "\(slug)-\(index)"
            index += 1
        }
        return candidate
    }
    
    private func makeUniqueGuidePackId(base: String) -> String {
        let slug = sanitizePackId(base)
        let fm = FileManager.default
        var candidate = slug
        var index = 2
        while fm.fileExists(atPath: localGuideSamplesDirectory.appendingPathComponent(candidate).path) {
            candidate = "\(slug)-\(index)"
            index += 1
        }
        return candidate
    }
}
