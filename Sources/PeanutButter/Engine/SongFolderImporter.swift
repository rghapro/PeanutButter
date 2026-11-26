import Foundation
import AppKit

public struct SongFolderMetadata: Equatable, Sendable {
    public let title: String?
    public let musicalKey: String?
    public let bpm: Double?

    public init(title: String?, musicalKey: String?, bpm: Double?) {
        self.title = title
        self.musicalKey = musicalKey
        self.bpm = bpm
    }
}

public struct SongFolderScanResult: Sendable {
    public let folderURL: URL
    public let inferredTitle: String?
    public let inferredKey: String?
    public let inferredBPM: Double?
    public let audioURLs: [URL]
    public let artworkURL: URL?
    public let artworkData: Data?

    public init(
        folderURL: URL,
        inferredTitle: String?,
        inferredKey: String? = nil,
        inferredBPM: Double? = nil,
        audioURLs: [URL],
        artworkURL: URL?,
        artworkData: Data?
    ) {
        self.folderURL = folderURL
        self.inferredTitle = inferredTitle
        self.inferredKey = inferredKey
        self.inferredBPM = inferredBPM
        self.audioURLs = audioURLs
        self.artworkURL = artworkURL
        self.artworkData = artworkData
    }
}

public enum SongFolderImporter {
    public static let supportedAudioExtensions: Set<String> = ["wav", "m4a", "mp3", "aif", "aiff", "flac"]
    public static let supportedImageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "tiff", "tif"]
    public static let genericFolderNames: Set<String> = ["stems", "multitracks", "audio", "tracks", "files", "downloads", "desktop", "documents"]
    private static let coverKeywords: [String] = ["cover", "artwork", "album", "folder", "front", "thumb"]
    private static let supportedBuilderKeys: Set<String> = [
        "C", "C#", "Db", "D", "Eb", "E", "F", "F#", "Gb", "G", "Ab", "A", "Bb", "B",
        "Cm", "C#m", "Dm", "Ebm", "Em", "Fm", "F#m", "Gm", "Abm", "Am", "Bbm", "Bm"
    ]

    public static func inferSongTitle(from folderURL: URL) -> String? {
        parseMetadata(from: folderURL).title
    }

    public static func parseMetadata(from folderURL: URL) -> SongFolderMetadata {
        let primary = folderURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !primary.isEmpty && !genericFolderNames.contains(primary.lowercased()) {
            return parseMetadata(fromFolderName: primary)
        }
        let parent = folderURL.deletingLastPathComponent().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !parent.isEmpty && !genericFolderNames.contains(parent.lowercased()) {
            return parseMetadata(fromFolderName: parent)
        }
        return SongFolderMetadata(title: nil, musicalKey: nil, bpm: nil)
    }

    public static func parseMetadata(fromFolderName rawName: String) -> SongFolderMetadata {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SongFolderMetadata(title: nil, musicalKey: nil, bpm: nil)
        }

        let primaryDelimiters = CharacterSet(charactersIn: "-–—|")
        let rawSegments = trimmed.components(separatedBy: primaryDelimiters)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let segments: [String]
        if rawSegments.count >= 2 {
            segments = rawSegments
        } else {
            let underscoreParts = trimmed.split(separator: "_").map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            if underscoreParts.count >= 2,
               underscoreParts.dropFirst().contains(where: {
                   extractExplicitBPM(in: $0) != nil || extractStandaloneBPM(in: $0) != nil || normalizeMusicalKey($0, requireUppercaseRoot: true) != nil
               }) {
                segments = underscoreParts
            } else {
                segments = rawSegments.isEmpty ? [trimmed] : rawSegments
            }
        }

        let title = segments.first.flatMap { $0.isEmpty ? nil : $0 }

        var detectedBPM: Double? = nil
        for seg in segments.reversed() {
            if let explicit = extractExplicitBPM(in: seg) {
                detectedBPM = explicit
                break
            }
        }
        if detectedBPM == nil && segments.count >= 2 {
            for idx in stride(from: segments.count - 1, through: 1, by: -1) {
                if let standalone = extractStandaloneBPM(in: segments[idx]) {
                    detectedBPM = standalone
                    break
                }
            }
        }

        var detectedKey: String? = nil
        if segments.count >= 2 {
            for idx in stride(from: segments.count - 1, through: 1, by: -1) {
                let seg = segments[idx]
                if let directKey = normalizeMusicalKey(seg, requireUppercaseRoot: true) {
                    detectedKey = directKey
                    break
                }
                let lowerSeg = seg.lowercased()
                if extractExplicitBPM(in: seg) != nil || lowerSeg.contains("key") {
                    let tokens = seg.split(whereSeparator: { $0.isWhitespace || $0 == "_" }).map(String.init)
                    for tok in tokens.reversed() {
                        if extractExplicitBPM(in: tok) != nil { continue }
                        if let tokKey = normalizeMusicalKey(tok, requireUppercaseRoot: true) {
                            detectedKey = tokKey
                            break
                        }
                    }
                    if detectedKey != nil { break }
                }
            }
        } else {
            if let keyOfMatch = firstRegexCapture(
                in: trimmed,
                pattern: #"(?i)\bkey\s+of\s+([A-Ga-g][#♯b♭]?(?:\s*(?:m|min|minor|maj|major))?)\b"#
            ) {
                detectedKey = normalizeMusicalKey(keyOfMatch, requireUppercaseRoot: false)
            } else if let bracketMatch = firstRegexCapture(
                in: trimmed,
                pattern: #"[\(\[]\s*([A-G][#♯b♭]?(?:\s*(?:m|min|minor|maj|major))?)\s*[\)\]]\s*$"#
            ) {
                detectedKey = normalizeMusicalKey(bracketMatch, requireUppercaseRoot: true)
            }
        }

        return SongFolderMetadata(title: title, musicalKey: detectedKey, bpm: detectedBPM)
    }

    private static func extractExplicitBPM(in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)(?:\b(\d{2,3}(?:\.\d{1,2})?)\s*bpm\b|\bbpm\s*[:=]?\s*(\d{2,3}(?:\.\d{1,2})?)\b)"#
        ) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        let capRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
        guard let swiftRange = Range(capRange, in: text),
              let val = Double(text[swiftRange]),
              val >= 20.0 && val <= 300.0 else {
            return nil
        }
        return (val * 100.0).rounded() / 100.0
    }

    private static func extractStandaloneBPM(in text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: #"^(\d{2,3}(?:\.\d{1,2})?)$"#) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range),
              let swiftRange = Range(match.range(at: 1), in: trimmed),
              let val = Double(trimmed[swiftRange]),
              val >= 40.0 && val <= 240.0 else {
            return nil
        }
        return (val * 100.0).rounded() / 100.0
    }

    private static func firstRegexCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }

    private static func normalizeMusicalKey(_ rawToken: String, requireUppercaseRoot: Bool) -> String? {
        var working = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if (working.hasPrefix("(") && working.hasSuffix(")")) || (working.hasPrefix("[") && working.hasSuffix("]")) {
            working = String(working.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var enforceUppercase = requireUppercaseRoot
        let lowerPrefix = working.lowercased()
        if lowerPrefix.hasPrefix("key of ") {
            working = String(working.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            enforceUppercase = false
        } else if lowerPrefix.hasPrefix("key ") {
            working = String(working.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            enforceUppercase = false
        }

        let compact = working.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: #"^([A-Ga-g])(#|♯|b|♭)?(m|min|minor|maj|major)?$"#, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(compact.startIndex..<compact.endIndex, in: compact)
        guard let match = regex.firstMatch(in: compact, range: range),
              let rootRange = Range(match.range(at: 1), in: compact) else {
            return nil
        }
        let rawRoot = String(compact[rootRange])
        let hasAccidental = match.range(at: 2).location != NSNotFound
        if enforceUppercase && !hasAccidental && rawRoot != rawRoot.uppercased() {
            return nil
        }

        var accidental = ""
        if hasAccidental, let accRange = Range(match.range(at: 2), in: compact) {
            let accStr = String(compact[accRange])
            if accStr == "#" || accStr == "♯" { accidental = "#" }
            else if accStr == "b" || accStr == "♭" { accidental = "b" }
        }

        var isMinor = false
        if match.range(at: 3).location != NSNotFound, let qualRange = Range(match.range(at: 3), in: compact) {
            let qual = compact[qualRange].lowercased()
            isMinor = (qual == "m" || qual == "min" || qual == "minor")
        }

        var candidate = "\(rawRoot.uppercased())\(accidental)\(isMinor ? "m" : "")"
        let enharmonicMap: [String: String] = [
            "D#": "Eb", "G#": "Ab", "A#": "Bb",
            "Dbm": "C#m", "D#m": "Ebm", "Gbm": "F#m", "G#m": "Abm", "A#m": "Bbm"
        ]
        candidate = enharmonicMap[candidate] ?? candidate
        return supportedBuilderKeys.contains(candidate) ? candidate : nil
    }

    public static func scan(folderURL: URL) -> SongFolderScanResult {
        let standardizedFolder = folderURL.standardizedFileURL
        let metadata = parseMetadata(from: standardizedFolder)
        let fm = FileManager.default
        let isDir = (try? standardizedFolder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isDir else {
            return SongFolderScanResult(
                folderURL: standardizedFolder,
                inferredTitle: metadata.title,
                inferredKey: metadata.musicalKey,
                inferredBPM: metadata.bpm,
                audioURLs: [],
                artworkURL: nil,
                artworkData: nil
            )
        }

        var audioURLs: [URL] = []
        var imageCandidates: [(url: URL, isTopLevel: Bool, isCoverKeyword: Bool)] = []
        let baseComponentsCount = standardizedFolder.pathComponents.count

        if let enumerator = fm.enumerator(
            at: standardizedFolder,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let rawURL as URL in enumerator {
                let fileURL = rawURL.standardizedFileURL
                let relComponents = Array(fileURL.pathComponents.dropFirst(baseComponentsCount))
                if relComponents.contains(where: { $0 == "__MACOSX" || $0.hasPrefix(".") }) {
                    if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }
                let ext = fileURL.pathExtension.lowercased()
                if supportedAudioExtensions.contains(ext) {
                    audioURLs.append(fileURL)
                } else if supportedImageExtensions.contains(ext) {
                    let isTopLevel = (fileURL.deletingLastPathComponent().standardizedFileURL == standardizedFolder)
                    let stemLower = fileURL.deletingPathExtension().lastPathComponent.lowercased()
                    let isCoverKeyword = coverKeywords.contains(where: { stemLower.contains($0) })
                    imageCandidates.append((url: fileURL, isTopLevel: isTopLevel, isCoverKeyword: isCoverKeyword))
                }
            }
        }

        audioURLs.sort {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        imageCandidates.sort { lhs, rhs in
            if lhs.isTopLevel != rhs.isTopLevel {
                return lhs.isTopLevel
            }
            if lhs.isCoverKeyword != rhs.isCoverKeyword {
                return lhs.isCoverKeyword
            }
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }

        var chosenArtworkURL: URL? = nil
        var chosenArtworkData: Data? = nil
        for candidate in imageCandidates {
            if let data = try? Data(contentsOf: candidate.url), !data.isEmpty, NSImage(data: data) != nil {
                chosenArtworkURL = candidate.url
                chosenArtworkData = data
                break
            }
        }

        return SongFolderScanResult(
            folderURL: standardizedFolder,
            inferredTitle: metadata.title,
            inferredKey: metadata.musicalKey,
            inferredBPM: metadata.bpm,
            audioURLs: audioURLs,
            artworkURL: chosenArtworkURL,
            artworkData: chosenArtworkData
        )
    }

    public static func findDefaultArtwork(in folderURL: URL) -> (url: URL, data: Data)? {
        let standardizedFolder = folderURL.standardizedFileURL
        let folderName = standardizedFolder.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !folderName.isEmpty, !genericFolderNames.contains(folderName) else {
            return nil
        }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: standardizedFolder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var candidates: [(url: URL, isCoverKeyword: Bool)] = []
        for rawURL in contents {
            let fileURL = rawURL.standardizedFileURL
            let name = fileURL.lastPathComponent
            if name.hasPrefix("._") || name.hasPrefix(".") { continue }
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let ext = fileURL.pathExtension.lowercased()
            guard supportedImageExtensions.contains(ext) else { continue }
            let stemLower = fileURL.deletingPathExtension().lastPathComponent.lowercased()
            let isCoverKeyword = coverKeywords.contains(where: { stemLower.contains($0) })
            candidates.append((url: fileURL, isCoverKeyword: isCoverKeyword))
        }

        candidates.sort { lhs, rhs in
            if lhs.isCoverKeyword != rhs.isCoverKeyword {
                return lhs.isCoverKeyword
            }
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }

        for candidate in candidates {
            if let data = try? Data(contentsOf: candidate.url), !data.isEmpty, NSImage(data: data) != nil {
                return (url: candidate.url, data: data)
            }
        }
        return nil
    }
}
