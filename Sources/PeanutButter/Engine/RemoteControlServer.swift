import Foundation
import Network
import CryptoKit
import CommonCrypto
import Darwin
import Combine

// MARK: - Bi-Directional JSON Protocol

public struct RemoteSectionInfo: Codable, Sendable {
    public let id: String
    public let name: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let isActive: Bool
    public let isQueued: Bool
    public let colorHex: String
}

public struct RemoteSongInfo: Codable, Sendable {
    public let index: Int
    public let id: String
    public let title: String
    public let artist: String
    public let bpm: Double
    public let musicalKey: String
    public let isActive: Bool
}

public struct RemoteTrackInfo: Codable, Sendable {
    public let id: String
    public let name: String
    public let shortName: String
    public let role: String
    public let volume: Float
    public let pan: Float
    public let isMuted: Bool
    public let isSoloed: Bool
    public let assignedBusName: String
}

public struct RemoteBusInfo: Codable, Sendable {
    public let id: String
    public let name: String
    public let shortName: String
    public let volume: Float
    public let isMuted: Bool
    public let isSoloed: Bool
    public let isSoloSafe: Bool
    public let physicalOutputChannel: String
    public let isMono: Bool
}

public struct RemotePadPackInfo: Codable, Sendable {
    public let id: String
    public let name: String
}

public struct RemotePadState: Codable, Sendable {
    public let isActive: Bool
    public let isLinked: Bool
    public let currentKey: String
    public let lockedKey: String?
    public let activePackId: String
    public let volume: Float
    public let pan: Float
    public let isMuted: Bool
    public let isSoloed: Bool
    public let packs: [RemotePadPackInfo]
}

public struct RemoteStateSnapshot: Codable, Sendable {
    public let type: String
    public let songTitle: String
    public let artist: String
    public let bpm: Double
    public let musicalKey: String
    public let isPlaying: Bool
    public let currentTime: TimeInterval
    public let duration: TimeInterval
    public let masterVolume: Float
    public let defaultFaderLevel: Float
    public let currentSongIndex: Int
    public let isLoopActive: Bool
    public let loopMode: String
    public let isPostSongClickActive: Bool
    public let waveformVersion: UInt64
    public let pad: RemotePadState
    public let sections: [RemoteSectionInfo]
    public let setlist: [RemoteSongInfo]
    public let tracks: [RemoteTrackInfo]
    public let buses: [RemoteBusInfo]
}

public struct RemoteWaveformPacket: Codable, Sendable {
    public let type: String
    public let version: UInt64
    public let duration: TimeInterval
    public let peaks: [Int]
}

public struct RemoteMetersPacket: Codable, Sendable {
    public let type: String
    public let master: [Int]
    public let pad: [Int]
    public let tracks: [String: [Int]]
    public let buses: [String: [Int]]
}

public struct RemoteCommand: Codable, Sendable {
    public let type: String
    public let sectionIndex: Int?
    public let songIndex: Int?
    public let trackId: String?
    public let busId: String?
    public let volume: Float?
    public let pan: Float?
    public let time: TimeInterval?
    public let password: String?
    public let padKey: String?
    public let padPackId: String?
}

// MARK: - PeanutButter Remote Server (Network.framework + Bonjour + WebSocket + HTTP)

/// Hosts a local HTTP + WebSocket server advertised via Bonjour (`_peanutbutter._tcp`)
/// so band members and engineers can control Transport, Mixer, and Setlist from any browser or iOS/Mac client.
@MainActor
public final class RemoteControlServer: ObservableObject {
    private static let passwordRequiredDefaultsKey = "Playback_RemotePasswordRequired"
    private static let passwordSaltDefaultsKey = "Playback_RemotePasswordSalt"
    private static let passwordHashDefaultsKey = "Playback_RemotePasswordHash"
    private static let passwordKDFDefaultsKey = "Playback_RemotePasswordKDF"
    private static let pbkdf2Identifier = "pbkdf2-sha256-100000"
    private nonisolated static let pbkdf2Rounds: UInt32 = 100_000
    private static let passwordDebounceNanoseconds: UInt64 = 300_000_000
    private static let legacyPlaintextPasswordDefaultsKey = "Playback_RemotePassword"

    private static let maxWebSocketClients = 32
    private static let maxFailedAuthAttempts = 5
    private static let authLockoutSeconds: TimeInterval = 30.0
    private static let maxAuthFailureRecords = 512
    private static let maxUnauthenticatedFrames = 8
    private static let maxInFlightAuthVerifications = 16
    private static let httpHeaderTimeoutSeconds: TimeInterval = 5.0

    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var port: UInt16 = 8085
    @Published public private(set) var connectedClientCount: Int = 0
    @Published public private(set) var localURLString: String = ""
    @Published public private(set) var lastError: String? = nil
    @Published public private(set) var hasConfiguredPassword: Bool = false
    public private(set) var pbkdf2DerivationCountForTesting: Int = 0

    @Published public var isPasswordRequired: Bool {
        didSet {
            guard !isInitializing else { return }
            userDefaults.set(isPasswordRequired, forKey: Self.passwordRequiredDefaultsKey)
            if isPasswordRequired {
                invalidateAuthenticatedClients()
            } else {
                for client in webSocketClients.values {
                    client.isAuthenticated = true
                    client.unauthenticatedMessageCount = 0
                }
                broadcastStateIfNeeded()
            }
        }
    }
    @Published public var remotePassword: String {
        didSet {
            guard !isInitializing && !isClearingPassword else { return }
            passwordCommitTask?.cancel()
            passwordCommitTask = nil
            if remotePassword.isEmpty {
                hasUncommittedPasswordDraft = false
                return
            }
            hasUncommittedPasswordDraft = true
            passwordCommitTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: Self.passwordDebounceNanoseconds)
                } catch {
                    return
                }
                self?.commitPendingPassword()
            }
        }
    }

    private struct AuthFailureRecord {
        var failedCount: Int
        var lockedUntil: Date?
    }

    private weak var engine: MultitrackAudioEngine?
    private let userDefaults: UserDefaults
    private let padLibrary: PadLibraryManager
    private var isInitializing: Bool = true
    private var isClearingPassword: Bool = false
    private var hasUncommittedPasswordDraft: Bool = false
    private var passwordCommitTask: Task<Void, Never>?
    private var listener: NWListener?
    private var webSocketClients: [ObjectIdentifier: WebSocketClient] = [:]
    private var authFailuresByIP: [String: AuthFailureRecord] = [:]
    private var inFlightAuthVerifications: Int = 0
    private var authConfigurationEpoch: UInt64 = 0
    private var cancellables: Set<AnyCancellable> = []
    private var broadcastTimer: Timer?
    private var meterTimer: Timer?
    private var lastMetersWereNonZero: Bool = false

    private let serverQueue = DispatchQueue(label: "com.peanutbutter.remote.server", qos: .userInitiated)
    private nonisolated static let authWorkerQueue = DispatchQueue(label: "com.peanutbutter.remote.auth", qos: .userInitiated)

    public init(
        engine: MultitrackAudioEngine? = nil,
        userDefaults: UserDefaults = .standard,
        padLibrary: PadLibraryManager = .shared
    ) {
        self.engine = engine
        self.userDefaults = userDefaults
        self.padLibrary = padLibrary
        self.isPasswordRequired = userDefaults.bool(forKey: Self.passwordRequiredDefaultsKey)
        self.remotePassword = ""

        if let legacyPlaintext = userDefaults.string(forKey: Self.legacyPlaintextPasswordDefaultsKey) {
            if !legacyPlaintext.isEmpty {
                storePasswordHash(legacyPlaintext)
            }
            userDefaults.removeObject(forKey: Self.legacyPlaintextPasswordDefaultsKey)
        }
        self.hasConfiguredPassword = Self.hasStoredHash(in: userDefaults)
        self.isInitializing = false
    }

    private var requiresAuthCheck: Bool {
        isPasswordRequired
    }

    private static func hasStoredHash(in defaults: UserDefaults) -> Bool {
        guard let saltB64 = defaults.string(forKey: passwordSaltDefaultsKey),
              let hashB64 = defaults.string(forKey: passwordHashDefaultsKey),
              let salt = Data(base64Encoded: saltB64),
              let hash = Data(base64Encoded: hashB64) else {
            return false
        }
        return !salt.isEmpty && hash.count == 32
    }

    private nonisolated static func randomBytes(count: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            bytes[i] = UInt8.random(in: UInt8.min...UInt8.max, using: &rng)
        }
        return Data(bytes)
    }

    private nonisolated static func derivePBKDF2SHA256(
        password: String,
        salt: Data,
        rounds: UInt32 = RemoteControlServer.pbkdf2Rounds
    ) -> Data? {
        var derived = [UInt8](repeating: 0, count: 32)
        let passwordData = Array(password.utf8)
        let status = passwordData.withUnsafeBufferPointer { pwBuf in
            salt.withUnsafeBytes { saltBuf in
                let pwPtr = pwBuf.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self) }
                let saltPtr = saltBuf.bindMemory(to: UInt8.self).baseAddress
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwPtr,
                    passwordData.count,
                    saltPtr,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    rounds,
                    &derived,
                    derived.count
                )
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(derived)
    }

    private nonisolated static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<lhs.count {
            diff |= lhs[lhs.startIndex + i] ^ rhs[rhs.startIndex + i]
        }
        return diff == 0
    }

    private func storePasswordHash(_ password: String) {
        let salt = Self.randomBytes(count: 16)
        guard let digest = Self.derivePBKDF2SHA256(password: password, salt: salt) else { return }
        pbkdf2DerivationCountForTesting += 1
        authConfigurationEpoch &+= 1

        userDefaults.set(salt.base64EncodedString(), forKey: Self.passwordSaltDefaultsKey)
        userDefaults.set(digest.base64EncodedString(), forKey: Self.passwordHashDefaultsKey)
        userDefaults.set(Self.pbkdf2Identifier, forKey: Self.passwordKDFDefaultsKey)
        userDefaults.removeObject(forKey: Self.legacyPlaintextPasswordDefaultsKey)
        hasConfiguredPassword = true
    }

    public func commitPendingPassword() {
        passwordCommitTask?.cancel()
        passwordCommitTask = nil
        guard hasUncommittedPasswordDraft, !remotePassword.isEmpty else {
            hasUncommittedPasswordDraft = false
            return
        }
        hasUncommittedPasswordDraft = false
        storePasswordHash(remotePassword)
        if isPasswordRequired {
            invalidateAuthenticatedClients()
        }
    }

    public func setPassword(_ password: String) {
        passwordCommitTask?.cancel()
        passwordCommitTask = nil
        hasUncommittedPasswordDraft = false
        isClearingPassword = true
        remotePassword = password
        isClearingPassword = false
        if password.isEmpty {
            clearPassword()
            return
        }
        storePasswordHash(password)
        if isPasswordRequired {
            invalidateAuthenticatedClients()
        }
    }

    public func clearPassword() {
        passwordCommitTask?.cancel()
        passwordCommitTask = nil
        hasUncommittedPasswordDraft = false
        authConfigurationEpoch &+= 1
        isClearingPassword = true
        remotePassword = ""
        isClearingPassword = false
        userDefaults.removeObject(forKey: Self.passwordSaltDefaultsKey)
        userDefaults.removeObject(forKey: Self.passwordHashDefaultsKey)
        userDefaults.removeObject(forKey: Self.passwordKDFDefaultsKey)
        userDefaults.removeObject(forKey: Self.legacyPlaintextPasswordDefaultsKey)
        hasConfiguredPassword = false
        isPasswordRequired = false
        userDefaults.set(false, forKey: Self.passwordRequiredDefaultsKey)
    }

    public func verifyPassword(_ candidate: String) -> Bool {
        guard let saltB64 = userDefaults.string(forKey: Self.passwordSaltDefaultsKey),
              let hashB64 = userDefaults.string(forKey: Self.passwordHashDefaultsKey),
              let salt = Data(base64Encoded: saltB64),
              let storedHash = Data(base64Encoded: hashB64),
              !salt.isEmpty,
              storedHash.count == 32 else {
            return false
        }

        let kdf = userDefaults.string(forKey: Self.passwordKDFDefaultsKey)
        if kdf == Self.pbkdf2Identifier {
            guard let candidateDigest = Self.derivePBKDF2SHA256(password: candidate, salt: salt) else {
                return false
            }
            return Self.constantTimeEqual(candidateDigest, storedHash)
        } else {
            // Migrate Pass-2 unslowed SHA-256 hash seamlessly upon valid login
            var payload = Data()
            payload.reserveCapacity(salt.count + candidate.utf8.count)
            payload.append(salt)
            payload.append(contentsOf: candidate.utf8)
            let candidateDigest = Data(SHA256.hash(data: payload))
            let matched = Self.constantTimeEqual(candidateDigest, storedHash)
            if matched {
                storePasswordHash(candidate)
            }
            return matched
        }
    }

    /// Runs 100k-round PBKDF2 verification off `@MainActor` so concurrent or repeated network auth
    /// requests cannot stall the UI thread or `@MainActor` MIDI cue dispatch.
    public func verifyPasswordAsync(_ candidate: String) async -> Bool {
        let epoch = authConfigurationEpoch
        guard let saltB64 = userDefaults.string(forKey: Self.passwordSaltDefaultsKey),
              let hashB64 = userDefaults.string(forKey: Self.passwordHashDefaultsKey),
              let salt = Data(base64Encoded: saltB64),
              let storedHash = Data(base64Encoded: hashB64),
              !salt.isEmpty,
              storedHash.count == 32 else {
            return false
        }

        let kdf = userDefaults.string(forKey: Self.passwordKDFDefaultsKey)
        if kdf == Self.pbkdf2Identifier {
            let matched: Bool = await withCheckedContinuation { continuation in
                Self.authWorkerQueue.async {
                    guard let candidateDigest = Self.derivePBKDF2SHA256(password: candidate, salt: salt) else {
                        continuation.resume(returning: false)
                        return
                    }
                    continuation.resume(returning: Self.constantTimeEqual(candidateDigest, storedHash))
                }
            }
            return matched && self.authConfigurationEpoch == epoch
        } else {
            var payload = Data()
            payload.reserveCapacity(salt.count + candidate.utf8.count)
            payload.append(salt)
            payload.append(contentsOf: candidate.utf8)
            let candidateDigest = Data(SHA256.hash(data: payload))
            let matched = Self.constantTimeEqual(candidateDigest, storedHash)
            guard matched else { return false }

            let newSalt = Self.randomBytes(count: 16)
            let newDigest: Data? = await withCheckedContinuation { continuation in
                Self.authWorkerQueue.async {
                    continuation.resume(returning: Self.derivePBKDF2SHA256(password: candidate, salt: newSalt))
                }
            }
            guard self.authConfigurationEpoch == epoch else { return false }
            if let digest = newDigest {
                pbkdf2DerivationCountForTesting += 1
                userDefaults.set(newSalt.base64EncodedString(), forKey: Self.passwordSaltDefaultsKey)
                userDefaults.set(digest.base64EncodedString(), forKey: Self.passwordHashDefaultsKey)
                userDefaults.set(Self.pbkdf2Identifier, forKey: Self.passwordKDFDefaultsKey)
                userDefaults.removeObject(forKey: Self.legacyPlaintextPasswordDefaultsKey)
                hasConfiguredPassword = true
            }
            return true
        }
    }

    private func invalidateAuthenticatedClients() {
        authConfigurationEpoch &+= 1
        for client in webSocketClients.values {
            client.isAuthenticated = false
            client.unauthenticatedMessageCount = 0
            client.lastSentWaveformVersion = nil
            client.sendText("{\"type\":\"authRequired\"}")
        }
    }

    public func isIPRateLimited(_ ip: String, now: Date = Date()) -> Bool {
        guard var record = authFailuresByIP[ip] else { return false }
        if let until = record.lockedUntil {
            if now < until {
                return true
            }
            record.failedCount = 0
            record.lockedUntil = nil
            authFailuresByIP[ip] = record
        }
        return false
    }

    public func recordAuthResult(success: Bool, forIP ip: String, now: Date = Date()) {
        if success {
            authFailuresByIP.removeValue(forKey: ip)
            return
        }
        var record = authFailuresByIP[ip] ?? AuthFailureRecord(failedCount: 0, lockedUntil: nil)
        if let until = record.lockedUntil, now >= until {
            record.failedCount = 0
            record.lockedUntil = nil
        }
        record.failedCount += 1
        if record.failedCount >= Self.maxFailedAuthAttempts {
            record.lockedUntil = now.addingTimeInterval(Self.authLockoutSeconds)
        }
        if authFailuresByIP[ip] == nil && authFailuresByIP.count >= Self.maxAuthFailureRecords {
            let expiredKeys = authFailuresByIP.compactMap { key, rec -> String? in
                if let until = rec.lockedUntil, now >= until { return key }
                return nil
            }
            for k in expiredKeys {
                authFailuresByIP.removeValue(forKey: k)
            }
            if authFailuresByIP.count >= Self.maxAuthFailureRecords, let victim = authFailuresByIP.keys.first {
                authFailuresByIP.removeValue(forKey: victim)
            }
        }
        authFailuresByIP[ip] = record
    }

    private nonisolated static func activeLocalInterfaceIPs() -> Set<String> {
        var ips: Set<String> = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return ips }
        defer { freeifaddrs(first) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            if let sa = current.pointee.ifa_addr {
                let family = sa.pointee.sa_family
                if family == UInt8(AF_INET) || family == UInt8(AF_INET6) {
                    var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &hostBuf, socklen_t(hostBuf.count), nil, 0, NI_NUMERICHOST) == 0 {
                        var ip = String(cString: hostBuf).lowercased()
                        if let pct = ip.firstIndex(of: "%") {
                            ip = String(ip[..<pct])
                        }
                        if !ip.isEmpty {
                            ips.insert(ip)
                        }
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return ips
    }

    public nonisolated static func isAllowedLocalHost(
        _ rawHost: String,
        extraAllowedHosts: Set<String> = []
    ) -> Bool {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }
        if host == "localhost" || extraAllowedHosts.contains(host) {
            return true
        }

        // Allow .local mDNS hostnames belonging to this Mac (Bonjour _peanutbutter._tcp)
        if host.hasSuffix(".local") {
            let processHost = ProcessInfo.processInfo.hostName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if host == processHost || host == "\(processHost).local" {
                return true
            }
            if let shortHost = processHost.split(separator: ".").first, !shortHost.isEmpty,
               host == "\(shortHost).local" {
                return true
            }
        }

        // Numeric IPv4 check: loopback, RFC1918 private LAN, link-local, CGNAT, or active interface IP
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let val = UInt32(bigEndian: ipv4.s_addr)
            let b0 = (val >> 24) & 0xFF
            let b1 = (val >> 16) & 0xFF
            if b0 == 127 { return true }                              // 127.0.0.0/8 loopback
            if b0 == 10 { return true }                               // 10.0.0.0/8 private
            if b0 == 172 && (16...31).contains(b1) { return true }    // 172.16.0.0/12 private
            if b0 == 192 && b1 == 168 { return true }                 // 192.168.0.0/16 private
            if b0 == 169 && b1 == 254 { return true }                 // 169.254.0.0/16 link-local
            if b0 == 100 && (64...127).contains(b1) { return true }   // 100.64.0.0/10 CGNAT
            return activeLocalInterfaceIPs().contains(host)
        }

        // Numeric IPv6 check: ::1 loopback, link-local fe80::/10, ULA fc00::/7, or active interface IP
        let ipv6NoZone = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, ipv6NoZone, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            let isLoopback = bytes[0..<15].allSatisfy { $0 == 0 } && bytes[15] == 1
            let isLinkLocal = bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80
            let isULA = (bytes[0] & 0xFE) == 0xFC
            if isLoopback || isLinkLocal || isULA { return true }
            return activeLocalInterfaceIPs().contains(ipv6NoZone)
        }

        return false
    }

    nonisolated static func isAllowedWebSocketOrigin(
        _ originHeader: String?,
        hostHeader: String?,
        serverPort: UInt16
    ) -> Bool {
        guard let rawOrigin = originHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawOrigin.isEmpty,
              rawOrigin.lowercased() != "null",
              let originComps = URLComponents(string: rawOrigin),
              let originScheme = originComps.scheme?.lowercased(),
              (originScheme == "http" || originScheme == "https"),
              let originHost = originComps.host?.lowercased(),
              !originHost.isEmpty else {
            return false
        }

        let originPort = originComps.port ?? (originScheme == "https" ? 443 : 80)

        guard let parsedHost = parseHostHeader(hostHeader, defaultPort: serverPort),
              isAllowedLocalHost(parsedHost.host),
              isAllowedLocalHost(originHost) else {
            return false
        }
        return originHost == parsedHost.host && originPort == parsedHost.port
    }

    private nonisolated static func parseHostHeader(
        _ hostHeader: String?,
        defaultPort: UInt16
    ) -> (host: String, port: Int)? {
        guard let raw = hostHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if raw.hasPrefix("[") {
            guard let closeIdx = raw.firstIndex(of: "]") else { return nil }
            let host = String(raw[raw.index(after: raw.startIndex)..<closeIdx]).lowercased()
            guard !host.isEmpty else { return nil }
            let afterBracket = raw[raw.index(after: closeIdx)...]
            if afterBracket.isEmpty {
                return (host, Int(defaultPort))
            }
            guard afterBracket.hasPrefix(":"),
                  let port = Int(afterBracket.dropFirst()),
                  (1...65535).contains(port) else {
                return nil
            }
            return (host, port)
        }

        if let colon = raw.firstIndex(of: ":") {
            let afterColon = raw[raw.index(after: colon)...]
            if afterColon.contains(":") {
                // Unbracketed IPv6 host without explicit port
                return (raw.lowercased(), Int(defaultPort))
            }
            let host = String(raw[..<colon]).lowercased()
            guard !host.isEmpty,
                  let port = Int(afterColon),
                  (1...65535).contains(port) else {
                return nil
            }
            return (host, port)
        }

        return (raw.lowercased(), Int(defaultPort))
    }

    private nonisolated static func remoteIPKey(for connection: NWConnection) -> String {
        switch connection.endpoint {
        case .hostPort(let host, _):
            return "\(host)"
        default:
            return connection.endpoint.debugDescription
        }
    }

    public func attach(to engine: MultitrackAudioEngine) {
        self.engine = engine
        cancellables.removeAll()

        engine.objectWillChange
            .throttle(for: .milliseconds(150), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                self?.broadcastStateIfNeeded()
            }
            .store(in: &cancellables)
    }

    public func start(preferredPort: UInt16 = 8085) {
        guard !isRunning else { return }
        lastError = nil
        startListener(on: preferredPort, allowEphemeralFallback: preferredPort != 0)
    }

    private func startListener(on requestedPort: UInt16, allowEphemeralFallback: Bool) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let newListener: NWListener
            if requestedPort == 0 {
                newListener = try NWListener(using: params)
            } else {
                let nwPort = NWEndpoint.Port(rawValue: requestedPort) ?? 8085
                newListener = try NWListener(using: params, on: nwPort)
            }

            let serviceName = Host.current().localizedName ?? "PeanutButter"
            newListener.service = NWListener.Service(name: serviceName, type: "_peanutbutter._tcp")

            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        if let boundPort = newListener.port?.rawValue {
                            self.port = boundPort
                        } else {
                            self.port = requestedPort
                        }
                        self.localURLString = self.computeLocalURL(port: self.port)
                        self.startBroadcastTimer()
                    case .failed(let error):
                        if allowEphemeralFallback {
                            newListener.cancel()
                            self.listener = nil
                            self.startListener(on: 0, allowEphemeralFallback: false)
                        } else {
                            self.lastError = error.localizedDescription
                            self.stop()
                        }
                    case .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.handleNewConnection(connection)
                }
            }

            self.listener = newListener
            newListener.start(queue: serverQueue)
        } catch {
            if allowEphemeralFallback {
                startListener(on: 0, allowEphemeralFallback: false)
            } else {
                lastError = error.localizedDescription
                isRunning = false
            }
        }
    }

    public func stop() {
        broadcastTimer?.invalidate()
        broadcastTimer = nil
        meterTimer?.invalidate()
        meterTimer = nil
        lastMetersWereNonZero = false

        listener?.cancel()
        listener = nil

        for client in webSocketClients.values {
            client.close()
        }
        webSocketClients.removeAll()
        connectedClientCount = 0
        isRunning = false
        localURLString = ""
    }

    private func startBroadcastTimer() {
        broadcastTimer?.invalidate()
        meterTimer?.invalidate()
        guard !webSocketClients.isEmpty else {
            broadcastTimer = nil
            meterTimer = nil
            lastMetersWereNonZero = false
            return
        }
        broadcastTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isRunning, !self.webSocketClients.isEmpty else { return }
                if self.engine?.playbackState == .playing {
                    self.broadcastStateIfNeeded()
                }
            }
        }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.055, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.broadcastMetersIfNeeded()
            }
        }
    }

    // MARK: - Connection Handling (HTTP + RFC 6455 WebSocket Upgrade)

    private final class HeaderDeadlineState: @unchecked Sendable {
        var completed = false
        var workItem: DispatchWorkItem?
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let deadline = HeaderDeadlineState()
        let timeoutItem = DispatchWorkItem { [weak connection] in
            guard !deadline.completed else { return }
            deadline.completed = true
            connection?.cancel()
        }
        deadline.workItem = timeoutItem
        connection.start(queue: serverQueue)
        serverQueue.asyncAfter(deadline: .now() + Self.httpHeaderTimeoutSeconds, execute: timeoutItem)
        receiveHTTPRequest(on: connection, accumulated: Data(), deadline: deadline)
    }

    private nonisolated func receiveHTTPRequest(
        on connection: NWConnection,
        accumulated: Data,
        deadline: HeaderDeadlineState
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if error != nil {
                deadline.completed = true
                deadline.workItem?.cancel()
                deadline.workItem = nil
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let data = data {
                buffer.append(data)
            }
            if let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                deadline.completed = true
                deadline.workItem?.cancel()
                deadline.workItem = nil
                let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
                let headerString = String(data: headerData, encoding: .utf8) ?? ""
                Task { @MainActor [weak self] in
                    await self?.routeHTTPRequest(headerString, on: connection)
                }
                return
            }
            if isComplete || buffer.count > 32768 {
                deadline.completed = true
                deadline.workItem?.cancel()
                deadline.workItem = nil
                connection.cancel()
                return
            }
            self.receiveHTTPRequest(on: connection, accumulated: buffer, deadline: deadline)
        }
    }

    private func routeHTTPRequest(_ headerString: String, on connection: NWConnection) async {
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            connection.cancel()
            return
        }
        let parts = requestLine.split(separator: " ")
        let rawPath = parts.count >= 2 ? String(parts[1]) : "/"
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = val
            }
        }

        guard let hostHdr = headers["host"],
              let parsedHost = Self.parseHostHeader(hostHdr, defaultPort: port),
              Self.isAllowedLocalHost(parsedHost.host) else {
            sendHTTPResponse(
                status: "403 Forbidden",
                contentType: "text/plain; charset=utf-8",
                body: Data("Forbidden Host".utf8),
                on: connection
            )
            return
        }

        if headers["upgrade"]?.lowercased() == "websocket",
           let secKey = headers["sec-websocket-key"] {
            guard Self.isAllowedWebSocketOrigin(headers["origin"], hostHeader: headers["host"], serverPort: port) else {
                sendHTTPResponse(
                    status: "403 Forbidden",
                    contentType: "text/plain; charset=utf-8",
                    body: Data("Forbidden Origin".utf8),
                    on: connection
                )
                return
            }
            guard webSocketClients.count < Self.maxWebSocketClients else {
                sendHTTPResponse(
                    status: "503 Service Unavailable",
                    contentType: "text/plain; charset=utf-8",
                    body: Data("Too many connected clients".utf8),
                    on: connection
                )
                return
            }
            upgradeToWebSocket(secKey: secKey, on: connection)
            return
        }

        if path == "/api/state" {
            if requiresAuthCheck {
                let ip = Self.remoteIPKey(for: connection)
                if isIPRateLimited(ip) {
                    sendHTTPResponse(
                        status: "429 Too Many Requests",
                        contentType: "application/json",
                        body: Data("{\"error\":\"Too many attempts\"}".utf8),
                        on: connection
                    )
                    return
                }
                guard inFlightAuthVerifications < Self.maxInFlightAuthVerifications else {
                    sendHTTPResponse(
                        status: "429 Too Many Requests",
                        contentType: "application/json",
                        body: Data("{\"error\":\"Auth busy\"}".utf8),
                        on: connection
                    )
                    return
                }
                inFlightAuthVerifications += 1
                defer { inFlightAuthVerifications = max(0, inFlightAuthVerifications - 1) }

                let supplied = headers["x-remote-password"] ?? ""
                let ok = await verifyPasswordAsync(supplied)
                if requiresAuthCheck {
                    if isIPRateLimited(ip) {
                        sendHTTPResponse(
                            status: "429 Too Many Requests",
                            contentType: "application/json",
                            body: Data("{\"error\":\"Too many attempts\"}".utf8),
                            on: connection
                        )
                        return
                    }
                    recordAuthResult(success: ok, forIP: ip)
                    if !ok {
                        sendHTTPResponse(
                            status: "401 Unauthorized",
                            contentType: "application/json",
                            body: Data("{\"error\":\"Unauthorized\"}".utf8),
                            on: connection
                        )
                        return
                    }
                }
            }
            if let snapshot = buildStateSnapshot(),
               let json = try? JSONEncoder().encode(snapshot) {
                sendHTTPResponse(
                    status: "200 OK",
                    contentType: "application/json; charset=utf-8",
                    body: json,
                    on: connection
                )
            } else {
                sendHTTPResponse(
                    status: "503 Service Unavailable",
                    contentType: "text/plain",
                    body: Data("Engine unavailable".utf8),
                    on: connection
                )
            }
            return
        }

        let cspNonce = Self.randomBytes(count: 16).base64EncodedString()
        let cspHeader = "default-src 'self'; script-src 'nonce-\(cspNonce)'; style-src 'unsafe-inline'; connect-src 'self' ws: wss:; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'"
        let htmlData = Data(Self.buildRemoteWebClientHTML(cspNonce: cspNonce).utf8)
        sendHTTPResponse(
            status: "200 OK",
            contentType: "text/html; charset=utf-8",
            body: htmlData,
            extraHeaders: [
                "Content-Security-Policy": cspHeader,
                "X-Content-Type-Options": "nosniff"
            ],
            on: connection
        )
    }

    private func sendHTTPResponse(
        status: String,
        contentType: String,
        body: Data,
        extraHeaders: [String: String] = [:],
        on connection: NWConnection
    ) {
        var headerLines = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "Cache-Control: no-store"
        ]
        for (k, v) in extraHeaders {
            headerLines.append("\(k): \(v)")
        }
        let header = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func upgradeToWebSocket(secKey: String, on connection: NWConnection) {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((secKey + magic).utf8))
        let accept = Data(digest).base64EncodedString()

        let handshake = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        let client = WebSocketClient(
            connection: connection,
            queue: serverQueue,
            ipAddress: Self.remoteIPKey(for: connection),
            isAuthenticated: !requiresAuthCheck
        )
        let clientId = ObjectIdentifier(client)
        webSocketClients[clientId] = client
        connectedClientCount = webSocketClients.count
        if broadcastTimer == nil {
            startBroadcastTimer()
        }

        client.onMessage = { [weak self, weak client] text in
            Task { @MainActor [weak self, weak client] in
                guard let self = self, let client = client else { return }
                await self.handleIncomingMessage(text, from: client)
            }
        }
        client.onClose = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.webSocketClients.removeValue(forKey: clientId)
                self.connectedClientCount = self.webSocketClients.count
                if self.webSocketClients.isEmpty {
                    self.broadcastTimer?.invalidate()
                    self.broadcastTimer = nil
                    self.meterTimer?.invalidate()
                    self.meterTimer = nil
                    self.lastMetersWereNonZero = false
                }
            }
        }

        connection.send(content: Data(handshake.utf8), completion: .contentProcessed { [weak self, weak client] error in
            if error != nil {
                client?.close()
                return
            }
            client?.startReading()
            Task { @MainActor [weak self, weak client] in
                guard let self = self, let client = client else { return }
                if client.isAuthenticated {
                    self.sendInitialStateAndWaveform(to: client)
                } else {
                    client.sendText("{\"type\":\"authRequired\"}")
                }
            }
        })
    }

    // MARK: - State & Command Dispatch

    public func buildStateSnapshot() -> RemoteStateSnapshot? {
        guard let engine = engine else { return nil }
        let song = engine.currentSong
        let currentTime = engine.playbackOffsetSeconds

        let queuedId = engine.queuedNextSection?.id
        let sections = song.sections.map { sec in
            RemoteSectionInfo(
                id: sec.id.uuidString,
                name: sec.name,
                startTime: sec.startTime,
                endTime: sec.endTime,
                isActive: currentTime >= sec.startTime && currentTime < sec.endTime,
                isQueued: queuedId == sec.id,
                colorHex: sec.colorHex
            )
        }

        let setlist = engine.currentSetlist.songs.enumerated().map { idx, item in
            RemoteSongInfo(
                index: idx,
                id: item.id.uuidString,
                title: item.title,
                artist: item.artist,
                bpm: item.bpm,
                musicalKey: item.currentTransposedKey,
                isActive: idx == engine.currentSongIndex
            )
        }

        let tracks = engine.tracks.map { track in
            RemoteTrackInfo(
                id: track.id.uuidString,
                name: track.name,
                shortName: StemCategory.abbreviatedName(for: track.name, role: track.role),
                role: track.role.rawValue,
                volume: track.volume,
                pan: track.pan,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed,
                assignedBusName: track.assignedBusName
            )
        }

        let buses = engine.busses.map { bus in
            RemoteBusInfo(
                id: bus.id.uuidString,
                name: bus.name,
                shortName: bus.abbreviatedName,
                volume: bus.volume,
                isMuted: bus.isMuted,
                isSoloed: bus.isSoloed,
                isSoloSafe: bus.isSoloSafe,
                physicalOutputChannel: bus.physicalOutputChannel,
                isMono: bus.isMono
            )
        }

        let padPacks = padLibrary.availablePacks.map {
            RemotePadPackInfo(id: $0.id, name: $0.name)
        }
        let rawActivePackId = (engine.padPlayer.isPlaying ? engine.padPlayer.activePackId : nil)
            ?? engine.manualPadPackId
            ?? engine.currentSong.padPresetId
            ?? engine.padPlayer.activePackId
            ?? padLibrary.activePackId
        let activePackId = padLibrary.resolvePack(for: rawActivePackId)?.id ?? "simple"

        let padState = RemotePadState(
            isActive: engine.isPadActive,
            isLinked: engine.isPadLinked,
            currentKey: engine.currentPadKey,
            lockedKey: engine.isPadKeyLockedToSong ? engine.linkedSongPadKey : nil,
            activePackId: activePackId,
            volume: engine.padChannelVolume,
            pan: engine.padChannelPan,
            isMuted: engine.padChannelMuted,
            isSoloed: engine.padChannelSoloed,
            packs: padPacks
        )

        let loopModeStr: String = {
            guard engine.isLoopActive else { return "none" }
            switch engine.loopMode {
            case .single: return "single"
            case .infinite: return "infinite"
            case .none: return "none"
            }
        }()

        return RemoteStateSnapshot(
            type: "state",
            songTitle: song.title,
            artist: song.artist,
            bpm: (engine.transportPosition.currentBPM > 20 ? engine.transportPosition.currentBPM : song.bpm),
            musicalKey: song.currentTransposedKey,
            isPlaying: engine.playbackState == .playing,
            currentTime: currentTime,
            duration: engine.currentSongDuration,
            masterVolume: engine.masterVolume,
            defaultFaderLevel: engine.defaultChannelFaderLevel,
            currentSongIndex: engine.currentSongIndex,
            isLoopActive: engine.isLoopActive,
            loopMode: loopModeStr,
            isPostSongClickActive: engine.isPostSongClickActive,
            waveformVersion: engine.waveformVersion,
            pad: padState,
            sections: sections,
            setlist: setlist,
            tracks: tracks,
            buses: buses
        )
    }

    public func buildWaveformPacket(targetBuckets: Int = 360) -> RemoteWaveformPacket? {
        guard let engine = engine else { return nil }
        let source = engine.aggregateWaveform
        let duration = engine.currentSongDuration
        let version = engine.waveformVersion

        guard !source.isEmpty, targetBuckets > 0 else {
            return RemoteWaveformPacket(type: "waveform", version: version, duration: duration, peaks: [])
        }

        let bucketCount = min(targetBuckets, source.count)
        var peaks: [Int] = []
        peaks.reserveCapacity(bucketCount)

        for b in 0..<bucketCount {
            let start = (b * source.count) / bucketCount
            let end = max(start + 1, ((b + 1) * source.count) / bucketCount)
            var peak: Float = 0.0
            for idx in start..<min(end, source.count) {
                let v = abs(source[idx])
                if v.isFinite && v > peak {
                    peak = v
                }
            }
            let clamped = max(0.0, min(1.0, peak))
            peaks.append(Int(round(clamped * 100.0)))
        }

        return RemoteWaveformPacket(
            type: "waveform",
            version: version,
            duration: duration,
            peaks: peaks
        )
    }

    private func encodedWaveformTextIfAvailable() -> (version: UInt64, text: String)? {
        guard let engine = engine,
              let packet = buildWaveformPacket(),
              let data = try? JSONEncoder().encode(packet),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return (engine.waveformVersion, text)
    }

    private func sendWaveformIfNeeded(to client: WebSocketClient, cached: (version: UInt64, text: String)? = nil) {
        guard let engine = engine, client.isAuthenticated else { return }
        let version = engine.waveformVersion
        guard client.lastSentWaveformVersion != version else { return }
        guard let resolved = cached ?? encodedWaveformTextIfAvailable() else { return }
        client.lastSentWaveformVersion = resolved.version
        client.sendText(resolved.text)
    }

    private func sendInitialStateAndWaveform(to client: WebSocketClient) {
        if let snapshot = buildStateSnapshot(),
           let json = try? JSONEncoder().encode(snapshot),
           let snapText = String(data: json, encoding: .utf8) {
            client.sendText(snapText)
        }
        sendWaveformIfNeeded(to: client)
    }

    public func buildMetersPacket() -> (packet: RemoteMetersPacket, isNonZero: Bool)? {
        guard let engine = engine else { return nil }
        func quantize(_ level: Float) -> Int {
            let clamped = max(0.0, min(1.0, level))
            return Int(round(clamped * 100.0))
        }

        let master = [quantize(engine.masterPeakLeft), quantize(engine.masterPeakRight)]
        let pad: [Int] = engine.padChannelMuted
            ? [0, 0]
            : [quantize(engine.padMeterPeakL), quantize(engine.padMeterPeakR)]

        var tracksDict: [String: [Int]] = [:]
        for track in engine.tracks {
            if track.isMuted { continue }
            let l = quantize(track.peakLevelLeft)
            let r = quantize(track.peakLevelRight)
            if l > 0 || r > 0 {
                tracksDict[track.id.uuidString] = [l, r]
            }
        }

        var busesDict: [String: [Int]] = [:]
        for bus in engine.busses {
            if bus.isMuted { continue }
            let l = quantize(bus.peakLevelLeft)
            let r = quantize(bus.peakLevelRight)
            if l > 0 || r > 0 {
                busesDict[bus.id.uuidString] = [l, r]
            }
        }

        let isNonZero = master[0] > 0 || master[1] > 0 || pad[0] > 0 || pad[1] > 0 || !tracksDict.isEmpty || !busesDict.isEmpty
        let packet = RemoteMetersPacket(
            type: "meters",
            master: master,
            pad: pad,
            tracks: tracksDict,
            buses: busesDict
        )
        return (packet, isNonZero)
    }

    public func broadcastStateIfNeeded() {
        guard isRunning, !webSocketClients.isEmpty,
              let snapshot = buildStateSnapshot(),
              let data = try? JSONEncoder().encode(snapshot),
              let text = String(data: data, encoding: .utf8) else { return }

        let authenticated = webSocketClients.values.filter { $0.isAuthenticated }
        guard !authenticated.isEmpty else { return }

        let needsWaveform = authenticated.contains { $0.lastSentWaveformVersion != snapshot.waveformVersion }
        let cachedWaveform = needsWaveform ? encodedWaveformTextIfAvailable() : nil

        for client in authenticated {
            client.sendText(text)
            if let wf = cachedWaveform, client.lastSentWaveformVersion != wf.version {
                client.lastSentWaveformVersion = wf.version
                client.sendText(wf.text)
            }
        }
    }

    private func broadcastMetersIfNeeded() {
        guard isRunning, !webSocketClients.isEmpty else { return }
        let authenticatedClients = webSocketClients.values.filter { $0.isAuthenticated }
        guard !authenticatedClients.isEmpty,
              let (packet, isNonZero) = buildMetersPacket() else { return }
        if !isNonZero && !lastMetersWereNonZero {
            return
        }
        lastMetersWereNonZero = isNonZero
        guard let data = try? JSONEncoder().encode(packet),
              let text = String(data: data, encoding: .utf8) else { return }
        for client in authenticatedClients {
            client.sendText(text)
        }
    }

    private func handleIncomingMessage(_ text: String) {
        guard !requiresAuthCheck else { return }
        guard let data = text.data(using: .utf8),
              let cmd = try? JSONDecoder().decode(RemoteCommand.self, from: data) else { return }
        applyCommand(cmd)
    }

    private func handleIncomingMessage(_ text: String, from client: WebSocketClient) async {
        guard let data = text.data(using: .utf8),
              let cmd = try? JSONDecoder().decode(RemoteCommand.self, from: data) else { return }

        if cmd.type == "auth" {
            if !requiresAuthCheck {
                client.isAuthenticated = true
                client.unauthenticatedMessageCount = 0
                sendInitialStateAndWaveform(to: client)
                return
            }

            if client.isAuthenticating || inFlightAuthVerifications >= Self.maxInFlightAuthVerifications {
                client.unauthenticatedMessageCount += 1
                client.sendText("{\"type\":\"authFailed\",\"locked\":false}")
                if client.unauthenticatedMessageCount > Self.maxUnauthenticatedFrames {
                    client.close()
                }
                return
            }

            if isIPRateLimited(client.ipAddress) {
                client.unauthenticatedMessageCount += 1
                client.sendText("{\"type\":\"authFailed\",\"locked\":true}")
                if client.unauthenticatedMessageCount > Self.maxUnauthenticatedFrames {
                    client.close()
                }
                return
            }

            client.isAuthenticating = true
            inFlightAuthVerifications += 1
            defer {
                client.isAuthenticating = false
                inFlightAuthVerifications = max(0, inFlightAuthVerifications - 1)
            }

            let ok = await verifyPasswordAsync(cmd.password ?? "")
            guard webSocketClients[ObjectIdentifier(client)] != nil else { return }
            if !requiresAuthCheck {
                client.isAuthenticated = true
                client.unauthenticatedMessageCount = 0
                sendInitialStateAndWaveform(to: client)
                return
            }
            if isIPRateLimited(client.ipAddress) {
                client.unauthenticatedMessageCount += 1
                client.sendText("{\"type\":\"authFailed\",\"locked\":true}")
                if client.unauthenticatedMessageCount > Self.maxUnauthenticatedFrames {
                    client.close()
                }
                return
            }

            recordAuthResult(success: ok, forIP: client.ipAddress)
            if ok {
                client.isAuthenticated = true
                client.unauthenticatedMessageCount = 0
                sendInitialStateAndWaveform(to: client)
            } else {
                client.unauthenticatedMessageCount += 1
                let locked = isIPRateLimited(client.ipAddress)
                client.sendText(locked ? "{\"type\":\"authFailed\",\"locked\":true}" : "{\"type\":\"authFailed\",\"locked\":false}")
                if client.unauthenticatedMessageCount > Self.maxUnauthenticatedFrames {
                    client.close()
                }
            }
            return
        }

        guard client.isAuthenticated else {
            client.unauthenticatedMessageCount += 1
            if client.unauthenticatedMessageCount > Self.maxUnauthenticatedFrames {
                client.close()
                return
            }
            client.sendText("{\"type\":\"authRequired\"}")
            return
        }

        applyCommand(cmd)
    }

    public func applyCommand(_ cmd: RemoteCommand) {
        guard let engine = engine else { return }
        var shouldBroadcastNow = true

        switch cmd.type {
        case "playPause":
            engine.togglePlayPause()
        case "play":
            if engine.playbackState != .playing { engine.play() }
        case "pause":
            if engine.playbackState == .playing { engine.pause() }
        case "rtz":
            engine.returnToZero()
        case "fade":
            engine.startFadeOut()
        case "toggleSingleLoop":
            engine.toggleSingleLoop()
        case "toggleInfiniteLoop":
            engine.toggleInfiniteLoop()
        case "seek":
            if let targetTime = cmd.time, targetTime.isFinite, engine.playbackState != .playing {
                engine.seek(to: max(0.0, targetTime))
            }
        case "jumpSection":
            if let idx = cmd.sectionIndex,
               idx >= 0,
               idx < engine.currentSong.sections.count {
                let sec = engine.currentSong.sections[idx]
                if engine.playbackState == .playing {
                    engine.queueNextSection(sec)
                } else {
                    engine.seek(to: sec.startTime)
                }
            }
        case "selectSong":
            if let idx = cmd.songIndex,
               idx >= 0,
               idx < engine.currentSetlist.songs.count {
                engine.selectSongInSetlist(at: idx)
            }
        case "nextSong":
            let nextIdx = engine.currentSongIndex + 1
            if nextIdx < engine.currentSetlist.songs.count {
                engine.selectSongInSetlist(at: nextIdx)
            }
        case "prevSong":
            let prevIdx = engine.currentSongIndex - 1
            if prevIdx >= 0 {
                engine.selectSongInSetlist(at: prevIdx)
            }
        case "setMasterVolume":
            if let vol = cmd.volume {
                engine.setMasterVolumeContinuous(vol)
                shouldBroadcastNow = false
            }
        case "setTrackVolume":
            if let idStr = cmd.trackId,
               let vol = cmd.volume,
               let track = engine.tracks.first(where: { $0.id.uuidString == idStr }) {
                track.volume = max(0.0, min(1.0, vol))
                engine.applyDirectTrackVolume(track)
                shouldBroadcastNow = false
            }
        case "setTrackPan":
            if let idStr = cmd.trackId,
               let pan = cmd.pan,
               let track = engine.tracks.first(where: { $0.id.uuidString == idStr }) {
                track.pan = max(-1.0, min(1.0, pan))
                engine.updateSingleTrackGain(track)
                shouldBroadcastNow = false
            }
        case "commitTrackMix":
            engine.updateMatrix()
        case "toggleMute":
            if let idStr = cmd.trackId,
               let track = engine.tracks.first(where: { $0.id.uuidString == idStr }) {
                track.isMuted.toggle()
                engine.updateMatrix()
            }
        case "toggleSolo":
            if let idStr = cmd.trackId,
               let track = engine.tracks.first(where: { $0.id.uuidString == idStr }) {
                track.isSoloed.toggle()
                engine.updateMatrix()
            }
        case "setBusVolume":
            if let idStr = cmd.busId,
               let vol = cmd.volume,
               let bus = engine.busses.first(where: { $0.id.uuidString == idStr }) {
                bus.volume = max(0.0, min(1.0, vol))
                engine.updateSingleBusGain(bus)
                shouldBroadcastNow = false
            }
        case "commitBusMix":
            if let idStr = cmd.busId,
               let bus = engine.busses.first(where: { $0.id.uuidString == idStr }) {
                engine.updateBusParameters(bus: bus)
            } else {
                engine.updateMatrix()
                engine.markSessionChanged()
            }
        case "toggleBusMute":
            if let idStr = cmd.busId,
               let bus = engine.busses.first(where: { $0.id.uuidString == idStr }) {
                bus.isMuted.toggle()
                engine.updateBusParameters(bus: bus)
            }
        case "toggleBusSolo":
            if let idStr = cmd.busId,
               let bus = engine.busses.first(where: { $0.id.uuidString == idStr }) {
                bus.isSoloed.toggle()
                engine.updateBusParameters(bus: bus)
            }
        case "togglePad":
            if engine.isPadActive {
                engine.stopPadPlayer()
            } else {
                let packId = engine.manualPadPackId ?? engine.currentSong.padPresetId ?? padLibrary.activePackId
                engine.startPadPlayer(packId: packId)
            }
        case "togglePadLink":
            engine.togglePadLink()
        case "setPadKey":
            if let key = cmd.padKey, !key.isEmpty {
                let normalized = AudioSampleBank.normalizeKeyForPad(key)
                if engine.isPadKeyLockedToSong, let lockedKey = engine.linkedSongPadKey, normalized != lockedKey {
                    break
                }
                if engine.isPadActive && engine.currentPadKey == normalized {
                    engine.stopPadPlayer()
                } else {
                    let packId = engine.manualPadPackId ?? engine.currentSong.padPresetId ?? padLibrary.activePackId
                    engine.startPadPlayer(key: normalized, packId: packId)
                }
            }
        case "setPadPack":
            if let packId = cmd.padPackId, !packId.isEmpty {
                engine.selectManualPadPack(id: packId)
            }
        case "setPadVolume":
            if let vol = cmd.volume {
                engine.padChannelVolume = max(0.0, min(1.0, vol))
                engine.updateMatrix()
                shouldBroadcastNow = false
            }
        case "setPadPan":
            if let pan = cmd.pan {
                engine.padChannelPan = max(-1.0, min(1.0, pan))
                engine.padPlayer.setPan(engine.padChannelPan)
                shouldBroadcastNow = false
            }
        case "commitPadMix":
            engine.updateMatrix()
            engine.markSessionChanged()
        case "togglePadMute":
            engine.padChannelMuted.toggle()
            engine.updateMatrix()
        case "togglePadSolo":
            engine.padChannelSoloed.toggle()
            engine.updateMatrix()
        default:
            break
        }

        if shouldBroadcastNow {
            broadcastStateIfNeeded()
        }
    }

    private func computeLocalURL(port: UInt16) -> String {
        var address = "localhost"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr {
            defer { freeifaddrs(ifaddr) }
            var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
            while let current = ptr {
                let flags = Int32(current.pointee.ifa_flags)
                let addr = current.pointee.ifa_addr.pointee
                if (flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING),
                   addr.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(current.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: hostname)
                        if !ip.hasPrefix("169.254.") {
                            address = ip
                            break
                        }
                    }
                }
                ptr = current.pointee.ifa_next
            }
        }
        return "http://\(address):\(port)"
    }
}

// MARK: - Thread-Safe RFC 6455 WebSocket Client Framing

private final class WebSocketClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var isClosed = false
    let ipAddress: String
    var isAuthenticated: Bool
    var isAuthenticating: Bool = false
    var unauthenticatedMessageCount: Int = 0
    var lastSentWaveformVersion: UInt64? = nil

    var onMessage: ((String) -> Void)?
    var onClose: (() -> Void)?

    init(connection: NWConnection, queue: DispatchQueue, ipAddress: String, isAuthenticated: Bool) {
        self.connection = connection
        self.queue = queue
        self.ipAddress = ipAddress
        self.isAuthenticated = isAuthenticated
    }

    func startReading() {
        queue.async { [weak self] in
            self?.receiveLoop()
        }
    }

    private func receiveLoop() {
        guard !isClosed else { return }
        connection.receive(minimumIncompleteLength: 2, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.isClosed else { return }
            if let data = data, !data.isEmpty {
                self.buffer.append(data)
                self.parseFrames()
            }
            if isComplete || error != nil {
                self.closeOnQueue()
                return
            }
            self.receiveLoop()
        }
    }

    private func parseFrames() {
        while buffer.count >= 2 {
            // Rebase to 0-indexed Data so offset math is always safe across multiple frames per packet
            if buffer.startIndex != 0 {
                buffer = Data(buffer)
            }

            let b0 = buffer[0]
            let b1 = buffer[1]
            let opcode = b0 & 0x0F
            let masked = (b1 & 0x80) != 0
            var length = UInt64(b1 & 0x7F)
            var offset = 2

            if length == 126 {
                guard buffer.count >= 4 else { return }
                length = (UInt64(buffer[2]) << 8) | UInt64(buffer[3])
                offset = 4
            } else if length == 127 {
                guard buffer.count >= 10 else { return }
                length = 0
                for i in 0..<8 {
                    length = (length << 8) | UInt64(buffer[2 + i])
                }
                offset = 10
            }

            guard length <= 1_048_576 else {
                closeOnQueue()
                return
            }

            let maskLen = masked ? 4 : 0
            let totalNeeded = offset + maskLen + Int(length)
            guard buffer.count >= totalNeeded else { return }

            var payload = Data(buffer[(offset + maskLen)..<totalNeeded])
            if masked {
                let maskKey = [buffer[offset], buffer[offset + 1], buffer[offset + 2], buffer[offset + 3]]
                for i in 0..<payload.count {
                    payload[i] ^= maskKey[i % 4]
                }
            }
            buffer = Data(buffer.dropFirst(totalNeeded))

            if opcode == 0x8 {
                closeOnQueue()
                return
            } else if opcode == 0x9 {
                sendFrameOnQueue(opcode: 0xA, payload: payload) // Pong
            } else if opcode == 0x1, let text = String(data: payload, encoding: .utf8) {
                onMessage?(text)
            }
        }
    }

    func sendText(_ text: String) {
        let payload = Data(text.utf8)
        queue.async { [weak self] in
            self?.sendFrameOnQueue(opcode: 0x1, payload: payload)
        }
    }

    private func sendFrameOnQueue(opcode: UInt8, payload: Data) {
        guard !isClosed else { return }
        var frame = Data([0x80 | opcode])
        let len = payload.count
        if len < 126 {
            frame.append(UInt8(len))
        } else if len <= 65535 {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((len >> shift) & 0xFF))
            }
        }
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.closeOnQueue()
            }
        })
    }

    func close() {
        queue.async { [weak self] in
            self?.closeOnQueue()
        }
    }

    private func closeOnQueue() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        onClose?()
    }
}

// MARK: - Embedded Responsive HTML5/JS Stage Remote Web Client

extension RemoteControlServer {
    static var remoteWebClientHTML: String {
        buildRemoteWebClientHTML(cspNonce: "static")
    }

    static func buildRemoteWebClientHTML(cspNonce: String) -> String {
        """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no" />
      <title>PeanutButter Remote</title>
      <style>
        :root {
          color-scheme: dark;
          --bg: #0f1115;
          --card: #181b22;
          --border: #2a2f3a;
          --accent: #35c46b;
          --blue: #3aa0ff;
          --red: #f04854;
          --amber: #f5a623;
          --text: #f3f5f8;
          --muted: #8b93a6;
          --setlist-w: 250px;
          --mixer-w: 350px;
          --dock-h: 310px;
        }
        * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
        ::-webkit-scrollbar { width: 8px; height: 8px; }
        ::-webkit-scrollbar-track { background: #12151c; border-radius: 999px; }
        ::-webkit-scrollbar-thumb { background: #303747; border-radius: 999px; border: 2px solid #12151c; }
        ::-webkit-scrollbar-thumb:hover { background: #434d63; }
        ::-webkit-scrollbar-thumb:active { background: #55617a; }
        ::-webkit-scrollbar-corner { background: transparent; }
        @supports not selector(::-webkit-scrollbar) {
          * { scrollbar-width: thin; scrollbar-color: #303747 #12151c; }
        }
        body {
          margin: 0; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
          background: var(--bg); color: var(--text); padding: 10px 14px; padding-bottom: 28px;
        }
        .header {
          display: flex; justify-content: space-between; align-items: center; gap: 10px;
          margin-bottom: 8px; flex-shrink: 0;
        }
        .brand { font-weight: 800; font-size: 14px; letter-spacing: 0.4px; }
        .header-right { display: flex; align-items: center; gap: 8px; }
        .timeline-select {
          padding: 4px 8px; border-radius: 8px; border: 1px solid var(--border);
          background: #181b22; color: var(--text); font-size: 11.5px; font-weight: 700;
        }
        .badge {
          font-size: 11px; font-weight: 700; padding: 4px 8px; border-radius: 999px;
          background: #232834; color: var(--muted); white-space: nowrap;
        }
        .badge.ok { background: rgba(53,196,107,0.16); color: var(--accent); }
        .card {
          background: var(--card); border: 1px solid var(--border);
          border-radius: 10px; padding: 10px 12px; margin-bottom: 10px;
        }
        .song-head {
          display: flex; flex-wrap: wrap; justify-content: space-between; align-items: baseline; gap: 8px;
        }
        .song-title-wrap { display: flex; align-items: baseline; gap: 8px; min-width: 0; }
        .song-title { font-size: 17px; font-weight: 800; margin: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .song-artist { font-size: 12px; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .song-meta { font-size: 12px; color: var(--muted); font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
        .transport {
          display: grid; grid-template-columns: repeat(4, 1fr); gap: 7px; margin-top: 8px;
        }
        button {
          border: none; border-radius: 8px; padding: 10px 8px; font-weight: 700;
          font-size: 13px; color: var(--text); background: #262b36; cursor: pointer;
        }
        button:active:not(:disabled) { transform: scale(0.97); }
        button:disabled { cursor: not-allowed; }
        button.play { background: var(--accent); color: #09140d; grid-column: span 2; }
        button.span2 { grid-column: span 2; }
        button.playing { background: var(--amber); color: #161005; }
        button.fade { background: rgba(240,72,84,0.2); color: #ff7a84; border: 1px solid rgba(240,72,84,0.35); }
        button.loop-active { background: rgba(77,163,255,0.22); color: var(--blue); border: 1px solid var(--blue); }
        button.stop-click { background: rgba(64,191,242,0.18); color: #40bff2; border: 1px solid rgba(64,191,242,0.55); }
        .section-title { font-size: 10.5px; font-weight: 800; letter-spacing: 0.8px; color: var(--muted); margin: 0 0 6px 0; text-transform: uppercase; }
        .sections-head { display: flex; justify-content: space-between; align-items: center; gap: 8px; margin-bottom: 6px; }
        .active-sec-pill { font-size: 11px; font-weight: 700; color: var(--blue); }
        .sections-grid { display: flex; flex-wrap: wrap; gap: 5px; }
        .sec-btn {
          padding: 6px 10px; font-size: 11.5px; background: #222732;
          border: 1px solid var(--border); border-left-width: 3px;
        }
        .sec-btn.active { background: var(--blue); color: #061320; border-color: var(--blue); }
        .sec-btn.queued { background: rgba(242,179,61,0.22); color: var(--amber); border-color: var(--amber); }

        /* Timeline (Waveform / Progress Bar / None) */
        .timeline-card { padding: 8px 10px; }
        .timeline-meta {
          display: flex; justify-content: space-between; align-items: center; gap: 8px;
          font-size: 11px; color: var(--muted); margin-bottom: 5px;
        }
        .timeline-mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
        #waveformCanvas {
          display: block; width: 100%; height: 54px; border-radius: 7px;
          background: #0c0e14; border: 1px solid #242936; cursor: pointer;
        }
        .prog-track {
          position: relative; width: 100%; height: 10px; border-radius: 999px;
          background: #0c0e14; border: 1px solid #262c38; overflow: hidden; cursor: pointer;
        }
        .prog-fill { height: 100%; width: 0%; background: var(--blue); border-radius: 999px; }
        .prog-ticks { position: absolute; inset: 0; pointer-events: none; }
        .prog-tick { position: absolute; top: 0; bottom: 0; width: 1px; background: rgba(255,255,255,0.22); }

        /* Setlist */
        .setlist-item {
          display: flex; justify-content: space-between; align-items: center; gap: 8px;
          padding: 8px 9px; border-radius: 8px; background: #1e222b; margin-bottom: 5px;
          cursor: pointer; border: 1px solid transparent; font-size: 12.5px;
        }
        .setlist-item.active { border-color: var(--accent); background: rgba(53,196,107,0.1); }
        .setlist-artist { font-size: 11px; color: var(--muted); }
        .setlist-meta { font-size: 11px; color: var(--muted); white-space: nowrap; }

        /* Cap-only Custom Horizontal Fader & Pan Controls */
        .hfader-well {
          position: relative; width: 100%; height: 22px; display: flex; align-items: center;
          touch-action: pan-y; cursor: default; user-select: none;
        }
        .hfader-well.pan-compact { height: 18px; }
        .hfader-track {
          position: relative; width: 100%; height: 4px; border-radius: 999px;
          background: #0c0e14; border: 1px solid #242936; pointer-events: none;
        }
        .hfader-well.pan-compact .hfader-track { height: 3px; }
        .hfader-fill {
          position: absolute; top: 0; bottom: 0; left: 0; border-radius: 999px;
          background: var(--blue); pointer-events: none;
        }
        .hfader-well.master-fader .hfader-fill { background: var(--accent); }
        .hfader-well.pan-fader .hfader-fill { background: #7890b0; }
        .hfader-tick {
          position: absolute; top: -3px; bottom: -3px; width: 1px;
          background: rgba(255,255,255,0.25); pointer-events: none;
        }
        .hfader-cap {
          position: absolute; top: 50%; width: 16px; height: 18px;
          transform: translate(-50%, -50%);
          left: calc(var(--p, 0.8) * (100% - 16px) + 8px);
          border-radius: 4px; pointer-events: auto; touch-action: none; cursor: ew-resize;
          background: linear-gradient(to bottom, #4e5668, #2e3442 60%, #222631);
          border: 1px solid rgba(255,255,255,0.32);
          box-shadow: 0 1px 4px rgba(0,0,0,0.65);
          display: flex; align-items: center; justify-content: center;
        }
        .hfader-cap::after { content: ""; position: absolute; inset: -7px -5px; }
        .hfader-cap-line { width: 2px; height: 10px; border-radius: 1px; background: #f3f5f8; }
        .hfader-well.master-fader .hfader-cap-line { background: #42ef7f; }
        .hfader-well.pan-fader .hfader-cap { width: 13px; height: 15px; }
        .hfader-well.pan-fader .hfader-cap { left: calc(var(--p, 0.5) * (100% - 13px) + 6.5px); }
        .hfader-well.pan-fader .hfader-cap-line { height: 8px; background: #cfd8e8; }
        .hfader-well.pan-compact .hfader-cap { width: 11px; height: 13px; }
        .hfader-well.pan-compact .hfader-cap { left: calc(var(--p, 0.5) * (100% - 11px) + 5.5px); }
        .hfader-cap.grabbing {
          border-color: var(--blue);
          box-shadow: 0 0 0 2px rgba(58,160,255,0.35), 0 2px 6px rgba(0,0,0,0.75);
        }

        /* Side Mixer Rows */
        .track-item { padding: 6px 0; border-bottom: 1px solid #222631; }
        .track-item:last-child { border-bottom: none; }
        .track-row {
          display: grid; grid-template-columns: 78px 1fr 27px 27px; gap: 7px; align-items: center;
        }
        .track-name-wrap { min-width: 0; }
        .track-name { font-size: 12.5px; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .bus-out {
          display: inline-block; font-size: 9.5px; font-weight: 700; color: var(--muted);
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace; margin-top: 1px;
        }
        .fader-meter-col { display: flex; flex-direction: column; gap: 3px; min-width: 0; }
        .pan-subrow {
          display: grid; grid-template-columns: 78px 28px 1fr 34px; gap: 6px; align-items: center;
          margin-top: 3px;
        }
        .pan-label { grid-column: 2; font-size: 9.5px; font-weight: 800; color: var(--muted); letter-spacing: 0.4px; }
        .pan-val {
          font-size: 10px; font-weight: 700; color: var(--muted); text-align: right;
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
        }
        input[type=password] {
          width: 100%; padding: 10px 12px; border-radius: 8px; border: 1px solid var(--border);
          background: #101218; color: var(--text); font-size: 14px; margin-bottom: 10px;
        }
        .mini-btn { padding: 5px 0; font-size: 11px; border-radius: 6px; font-weight: 800; }
        .mini-btn.muted { background: var(--red); color: white; }
        .mini-btn.soloed { background: var(--amber); color: #161005; }
        .mini-btn.solo-safe { box-shadow: inset 0 0 0 1.5px var(--amber); color: var(--amber); }

        /* GPU-accelerated Horizontal Stereo VU Meters */
        .vu-hpair { display: flex; flex-direction: column; gap: 2px; width: 100%; }
        .vu-hbar {
          position: relative; width: 100%; height: 3.5px; border-radius: 2px; overflow: hidden;
          background: linear-gradient(to right, #2ad468 0%, #35c46b 68%, #f5b923 86%, #f04854 100%);
        }
        .vu-hmask {
          position: absolute; inset: 0; background: #10131a;
          transform-origin: right center; transform: scaleX(1); will-change: transform;
        }

        /* Compact Pad Player */
        .pad-header { display: flex; justify-content: space-between; align-items: center; gap: 8px; margin-bottom: 7px; }
        .pad-head-left { display: flex; align-items: center; gap: 8px; min-width: 0; flex: 1; }
        .pad-actions { display: flex; gap: 6px; shrink: 0; }
        .pad-fire {
          padding: 5px 12px; font-size: 11px; font-weight: 800; letter-spacing: 0.6px;
          background: #1d2028; color: #42ef7f; border: 1.5px solid #303644; border-radius: 7px;
        }
        .pad-fire.active {
          background: rgba(53,196,107,0.14); color: #42ef7f;
          border-color: #35c46b; box-shadow: 0 0 10px rgba(53,196,107,0.2);
        }
        .pad-link { padding: 5px 9px; font-size: 11px; font-weight: 800; background: #1d2028; color: #7a8396; border: 1px solid #303644; border-radius: 7px; }
        .pad-link.linked { background: rgba(53,196,107,0.14); color: #42ef7f; border-color: rgba(53,196,107,0.5); }
        select.pad-select {
          flex: 1; max-width: 210px; min-width: 110px; padding: 5px 8px; border-radius: 7px;
          border: 1px solid var(--border); background: #101218; color: var(--text); font-size: 12px; font-weight: 600;
        }
        .keys-grid { display: grid; grid-template-columns: repeat(6, 1fr); gap: 5px; margin-bottom: 7px; }
        .key-btn { padding: 7px 2px; font-size: 12px; font-weight: 700; background: #20242d; border: 1px solid #303644; border-radius: 6px; color: var(--text); }
        .key-btn.selected { border-color: rgba(255,255,255,0.35); }
        .key-btn.active { background: rgba(53,196,107,0.2); color: #42ef7f; border-color: #35c46b; box-shadow: 0 0 8px rgba(53,196,107,0.18); }
        .key-btn.locked-target { border-color: rgba(53,196,107,0.65); }
        .key-btn.locked { opacity: 0.28; background: #161920; color: #697080; }
        .pad-bottom-row {
          display: flex; flex-wrap: wrap; align-items: center; gap: 10px;
        }
        .pad-vol-group { display: flex; align-items: center; gap: 7px; flex: 1 1 160px; min-width: 130px; }
        .pad-pan-group { display: flex; align-items: center; gap: 6px; flex: 0 1 140px; min-width: 115px; }
        .pad-ms-group { display: flex; align-items: center; gap: 5px; flex-shrink: 0; }
        .pad-ms-group .mini-btn { width: 28px; }
        .pad-sub-label { font-size: 10px; font-weight: 800; color: var(--muted); letter-spacing: 0.4px; flex-shrink: 0; }

        /* Mixer Card Header Controls */
        .mixer-topbar {
          display: flex; justify-content: space-between; align-items: center; gap: 8px;
          margin-bottom: 8px; flex-wrap: wrap; flex-shrink: 0;
        }
        .seg-tabs {
          display: inline-flex; background: #10131a; border: 1px solid var(--border);
          border-radius: 8px; padding: 2px; gap: 2px;
        }
        .seg-tab {
          padding: 4px 10px; font-size: 11px; font-weight: 800; border-radius: 6px;
          background: transparent; color: var(--muted); letter-spacing: 0.3px;
        }
        .seg-tab.active { background: #263144; color: #ffffff; }
        .mixer-top-right { display: flex; align-items: center; gap: 8px; }
        .hint-txt { font-size: 10.5px; color: var(--muted); }
        .layout-btn {
          padding: 4px 10px; font-size: 11px; font-weight: 700; border-radius: 7px;
          background: #202531; border: 1px solid var(--border); color: var(--text);
        }
        .layout-btn.active { background: rgba(58,160,255,0.18); color: var(--blue); border-color: rgba(58,160,255,0.5); }

        /* Horizontal Console Strips (Cap-Only Vertical Fader Dragging) */
        .console-rack {
          display: flex; align-items: stretch; gap: 8px; width: 100%; height: 100%; min-height: 215px;
        }
        .console-divider { width: 1px; background: var(--border); flex-shrink: 0; margin: 4px 0; }
        .console-scroll {
          flex: 1; display: flex; gap: 7px; overflow-x: auto; overflow-y: hidden;
          padding-bottom: 6px; align-items: stretch; min-width: 0;
        }
        .console-strip {
          flex: 0 0 74px; display: flex; flex-direction: column; align-items: center; gap: 5px;
          padding: 6px 5px; background: #12151c; border: 1px solid #242936; border-radius: 8px;
          min-height: 0;
        }
        .console-strip.master-strip { flex: 0 0 78px; border-color: rgba(53,196,107,0.38); background: #111815; }
        .strip-btns { display: grid; grid-template-columns: 1fr 1fr; gap: 4px; width: 100%; flex-shrink: 0; }
        .strip-btns .mini-btn { padding: 4px 0; font-size: 10.5px; }
        .strip-badge {
          width: 100%; text-align: center; font-size: 9.5px; font-weight: 800; padding: 4px 2px;
          border-radius: 5px; background: rgba(53,196,107,0.16); color: var(--accent); letter-spacing: 0.5px;
          flex-shrink: 0;
        }
        .strip-pan-wrap { width: 100%; display: flex; flex-direction: column; align-items: center; gap: 1px; flex-shrink: 0; }
        .strip-submeta {
          font-size: 9px; font-weight: 700; color: var(--muted);
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 100%;
          flex-shrink: 0;
        }
        .strip-bus-pill {
          font-size: 8.5px; font-weight: 800; color: #b7c2d6; background: #1c202a;
          border: 1px solid #2b3140; border-radius: 4px; padding: 2px 5px;
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace; flex-shrink: 0;
        }
        .vfader-well {
          position: relative; flex: 1; min-height: 105px; width: 100%;
          touch-action: pan-x; cursor: default; user-select: none;
        }
        .vfader-groove {
          position: absolute; left: 50%; top: 4px; bottom: 4px; width: 3px;
          transform: translateX(-50%); background: #090b0f; border-radius: 2px;
          box-shadow: inset 0 0 0 1px #1d222e; pointer-events: none;
        }
        .vfader-unity {
          position: absolute; left: 50%; width: 22px; height: 1px;
          transform: translateX(-50%); bottom: calc(0.8 * (100% - 22px) + 11px);
          background: rgba(255,255,255,0.22); pointer-events: none;
        }
        .vu-vbar {
          position: absolute; top: 4px; bottom: 4px; width: 4px; border-radius: 2px; overflow: hidden;
          background: linear-gradient(to top, #2ad468 0%, #35c46b 68%, #f5b923 86%, #f04854 100%);
          pointer-events: none;
        }
        .vu-vbar.left { left: 4px; }
        .vu-vbar.right { right: 4px; }
        .vu-vmask {
          position: absolute; inset: 0; background: #0c0e14;
          transform-origin: top center; transform: scaleY(1); will-change: transform;
        }
        .vfader-cap {
          position: absolute; left: 50%; width: 36px; height: 22px;
          transform: translateX(-50%);
          bottom: calc(var(--v, 0.8) * (100% - 22px));
          border-radius: 4px; pointer-events: auto; touch-action: none; cursor: ns-resize;
          background: linear-gradient(to bottom, #4a5162, #2d3340 55%, #20242e);
          border: 1px solid rgba(255,255,255,0.32);
          box-shadow: 0 2px 6px rgba(0,0,0,0.65);
          display: flex; align-items: center; justify-content: center;
        }
        .vfader-cap::after { content: ""; position: absolute; inset: -7px -5px; }
        .vfader-cap.grabbing {
          border-color: var(--blue);
          box-shadow: 0 0 0 2px rgba(58,160,255,0.35), 0 3px 10px rgba(0,0,0,0.8);
        }
        .vfader-cap-line { width: 26px; height: 2.5px; border-radius: 1px; background: #f3f5f8; pointer-events: none; }
        .vfader-cap.click .vfader-cap-line { background: #38b6ff; }
        .vfader-cap.guide .vfader-cap-line { background: #f5a623; }
        .vfader-cap.pad .vfader-cap-line { background: #35c46b; }
        .vfader-cap.master .vfader-cap-line { background: #42ef7f; }
        .vfader-cap.muted .vfader-cap-line { background: #646b7a; }
        .strip-name {
          width: 100%; text-align: center; font-size: 11px; font-weight: 800; color: var(--text);
          white-space: nowrap; overflow: hidden; text-overflow: ellipsis; flex-shrink: 0;
          padding-top: 2px;
        }

        /* Resizable Splitters (Desktop) */
        .splitter { display: none; align-items: center; justify-content: center; user-select: none; touch-action: none; }
        .splitter-grip { border-radius: 999px; background: #2c3342; transition: background 0.12s ease; }
        .splitter-v { cursor: col-resize; width: 10px; height: 100%; }
        .splitter-v .splitter-grip { width: 3px; height: 42px; }
        .splitter-h { cursor: row-resize; width: 100%; height: 10px; }
        .splitter-h .splitter-grip { width: 48px; height: 3px; }
        .splitter:hover .splitter-grip, .splitter.dragging .splitter-grip { background: var(--blue); }

        @media (max-width: 899px) {
          #mainUI { display: flex; flex-direction: column; gap: 10px; }
          .col-mixer .card { margin-bottom: 0; }
          .col-mixer.is-horizontal #mixerBody { height: 265px; }
        }

        @media (min-width: 900px) {
          body {
            padding: 10px 14px; max-width: 100%; height: 100vh; overflow: hidden;
            display: flex; flex-direction: column;
          }
          #mainUI.desktop-grid {
            flex: 1; min-height: 0; display: grid; gap: 0; align-items: stretch;
          }
          #mainUI.desktop-grid.layout-side {
            grid-template-columns: var(--setlist-w, 250px) 10px minmax(340px, 1fr) 10px var(--mixer-w, 350px);
            grid-template-rows: minmax(0, 1fr);
            grid-template-areas: "setlist splitL center splitR mixer";
          }
          #mainUI.desktop-grid.layout-side #splitterLeft { grid-area: splitL; display: flex; }
          #mainUI.desktop-grid.layout-side #splitterRight { grid-area: splitR; display: flex; }
          #mainUI.desktop-grid.layout-side #splitterBottom { display: none; }

          #mainUI.desktop-grid.layout-horizontal {
            grid-template-columns: var(--setlist-w, 250px) 10px minmax(360px, 1fr);
            grid-template-rows: auto 10px minmax(220px, 1fr);
            grid-template-areas:
              "setlist splitL center"
              "splitB splitB splitB"
              "mixer mixer mixer";
          }
          #mainUI.desktop-grid.layout-horizontal.custom-dock-h {
            grid-template-rows: minmax(190px, 1fr) 10px var(--dock-h, 310px);
          }
          #mainUI.desktop-grid.layout-horizontal #splitterLeft { grid-area: splitL; display: flex; }
          #mainUI.desktop-grid.layout-horizontal #splitterRight { display: none; }
          #mainUI.desktop-grid.layout-horizontal #splitterBottom { grid-area: splitB; display: flex; }

          .col-setlist { grid-area: setlist; min-height: 0; }
          .col-center {
            grid-area: center; min-height: 0; overflow-y: auto;
            display: flex; flex-direction: column; gap: 8px;
          }
          #mainUI.desktop-grid.layout-side .col-setlist,
          #mainUI.desktop-grid.layout-side .col-center,
          #mainUI.desktop-grid.layout-side .col-mixer { height: 100%; }
          .col-mixer { grid-area: mixer; min-height: 0; }
          .col-setlist .card, .col-mixer .card {
            height: 100%; display: flex; flex-direction: column; margin-bottom: 0;
          }
          .col-center .card { margin-bottom: 0; padding: 9px 11px; }
          #setlist { flex: 1; overflow-y: auto; min-height: 0; }
          #mixerBody { flex: 1; overflow-y: auto; min-height: 0; }
          .col-mixer.is-horizontal #mixerBody { overflow: hidden; display: flex; }

          /* Compact Single-Row Transport on Desktop */
          .transport {
            grid-template-columns: repeat(12, 1fr); gap: 6px; margin-top: 7px;
          }
          .transport button { padding: 7px 4px; font-size: 12px; white-space: nowrap; }
          .transport button.play { grid-column: span 2; }
          .transport button.span2 { grid-column: span 2; }

          /* Single-Row 12-Key Pad Grid on Desktop */
          .keys-grid { grid-template-columns: repeat(12, 1fr); gap: 5px; }
          .key-btn { padding: 6px 2px; font-size: 12px; }
          .sec-btn { padding: 5px 9px; font-size: 11.5px; }
          .track-row { grid-template-columns: 74px 1fr 26px 26px; gap: 6px; }
          .pan-subrow { grid-template-columns: 74px 26px 1fr 34px; }
          .setlist-item { padding: 7px 8px; font-size: 12px; }
        }
      </style>
    </head>
    <body>
      <div class="header">
        <div class="brand">PEANUTBUTTER REMOTE</div>
        <div class="header-right">
          <select id="timelineModeSelect" class="timeline-select" title="Timeline display mode">
            <option value="waveform">Waveform</option>
            <option value="progress">Progress Bar</option>
            <option value="none">None</option>
          </select>
          <div id="conn" class="badge">Connecting...</div>
        </div>
      </div>

      <div id="authCard" class="card" style="display:none;">
        <div class="section-title">Password Required</div>
        <input id="pwInput" type="password" placeholder="Enter remote password..." />
        <button id="unlockBtn" class="play" style="width:100%;">Unlock Remote</button>
        <div id="authErr" style="color:#ff7a84;font-size:12px;margin-top:8px;"></div>
      </div>

      <div id="mainUI" class="desktop-grid layout-side">
        <div class="col-setlist">
          <div class="card">
            <div class="section-title">Setlist</div>
            <div id="setlist"></div>
          </div>
        </div>

        <div id="splitterLeft" class="splitter splitter-v" title="Drag to resize • Double-click to reset">
          <div class="splitter-grip"></div>
        </div>

        <div class="col-center">
          <div class="card">
            <div class="song-head">
              <div class="song-title-wrap">
                <h1 id="songTitle" class="song-title">No Song Loaded</h1>
                <span id="songArtist" class="song-artist"></span>
              </div>
              <div id="songMeta" class="song-meta">-- BPM • Key -- • 0:00 / 0:00</div>
            </div>
            <div class="transport">
              <button id="playBtn" class="play">PLAY</button>
              <button id="rtzBtn">RTZ</button>
              <button id="fadeBtn" class="fade">FADE</button>
              <button id="prevSongBtn" class="span2">Prev Song</button>
              <button id="nextSongBtn" class="span2">Next Song</button>
              <button id="loop1xBtn" class="span2">Loop 1x</button>
              <button id="loopInfBtn" class="span2">Loop Infinite</button>
            </div>
          </div>

          <div id="timelineCard" class="card timeline-card">
            <div id="waveformWrap">
              <div class="timeline-meta">
                <span id="waveHint">Tap to seek</span>
                <span id="waveRemTime" class="timeline-mono">-0:00</span>
              </div>
              <canvas id="waveformCanvas"></canvas>
            </div>
            <div id="progressWrap" style="display:none;">
              <div class="timeline-meta timeline-mono">
                <span id="progElapsed">0:00</span>
                <span id="progSecName" style="font-family:inherit;font-weight:700;color:var(--blue);"></span>
                <span id="progRem">-0:00</span>
              </div>
              <div id="progressBarTrack" class="prog-track">
                <div id="progressBarFill" class="prog-fill"></div>
                <div id="progressTicks" class="prog-ticks"></div>
              </div>
            </div>
          </div>

          <div class="card">
            <div class="sections-head">
              <div class="section-title" style="margin:0;">Sections</div>
              <div id="activeSecLabel" class="active-sec-pill"></div>
            </div>
            <div id="sections" class="sections-grid"></div>
          </div>

          <div class="card">
            <div class="pad-header">
              <div class="pad-head-left">
                <div class="section-title" style="margin:0;flex-shrink:0;">Pad</div>
                <select id="padPackSelect" class="pad-select"></select>
              </div>
              <div class="pad-actions">
                <button id="padLinkBtn" class="pad-link">LINK</button>
                <button id="padFireBtn" class="pad-fire">PAD</button>
              </div>
            </div>
            <div id="padKeys" class="keys-grid"></div>
            <div class="pad-bottom-row">
              <div class="pad-vol-group">
                <span class="pad-sub-label">VOL</span>
                <div class="fader-meter-col" style="flex:1;">
                  <div id="padVolSlot"></div>
                  <div class="vu-hpair">
                    <div class="vu-hbar"><div id="padMeterL" class="vu-hmask"></div></div>
                    <div class="vu-hbar"><div id="padMeterR" class="vu-hmask"></div></div>
                  </div>
                </div>
              </div>
              <div class="pad-pan-group">
                <span class="pad-sub-label">PAN</span>
                <div id="padPanSlot" style="flex:1;"></div>
                <div id="padPanVal" class="pan-val">C</div>
              </div>
              <div class="pad-ms-group">
                <button id="padMuteBtn" class="mini-btn">M</button>
                <button id="padSoloBtn" class="mini-btn">S</button>
              </div>
            </div>
          </div>
        </div>

        <div id="splitterRight" class="splitter splitter-v" title="Drag to resize • Double-click to reset">
          <div class="splitter-grip"></div>
        </div>

        <div id="splitterBottom" class="splitter splitter-h" title="Drag to resize • Double-click to reset">
          <div class="splitter-grip"></div>
        </div>

        <div id="colMixer" class="col-mixer">
          <div class="card">
            <div class="mixer-topbar">
              <div class="seg-tabs">
                <button id="mixerTabTracks" class="seg-tab active">Tracks</button>
                <button id="mixerTabBuses" class="seg-tab">Buses</button>
              </div>
              <div class="mixer-top-right">
                <span class="hint-txt">drag cap (dbl-tap 0 dB)</span>
                <button id="mixerLayoutBtn" class="layout-btn">Horizontal</button>
              </div>
            </div>
            <div id="sideMasterRow" class="track-row" style="padding-bottom:7px;border-bottom:1px solid #222631;margin-bottom:4px;flex-shrink:0;">
              <div class="track-name">MASTER</div>
              <div class="fader-meter-col">
                <div id="masterVolSlot"></div>
                <div class="vu-hpair">
                  <div class="vu-hbar"><div id="masterMeterL" class="vu-hmask"></div></div>
                  <div class="vu-hbar"><div id="masterMeterR" class="vu-hmask"></div></div>
                </div>
              </div>
              <div></div><div></div>
            </div>
            <div id="mixerBody">
              <div id="tracks"></div>
            </div>
          </div>
        </div>
      </div>

      <script nonce="\(cspNonce)">
        let ws;
        let lastState = null;
        let lastMeters = null;
        let lastWaveform = { version: -1, duration: 0, peaks: [] };
        let playheadBaseTime = 0;
        let playheadBasePerf = performance.now();
        let rafId = null;

        let activeSlider = null;
        let lastSliderAt = 0;
        let renderedMixerKey = "";
        let lastPackIdsKey = "";
        let defaultFaderLevel = 0.80;
        let tapState = {};
        let consoleMasterEntry = null;
        let masterHFader = null;
        let padVolHFader = null;
        let padPanHFader = null;
        const trackDomById = new Map();
        const busDomById = new Map();
        const PAD_KEYS = ["Db", "Eb", "Gb", "Ab", "Bb", "B", "C", "D", "E", "F", "G", "A"];

        let mixerTab = loadPref("pb_remote_mixer_tab", "tracks");
        if (mixerTab !== "tracks" && mixerTab !== "buses") mixerTab = "tracks";
        let mixerLayout = loadPref("pb_remote_mixer_layout", "side");
        if (mixerLayout !== "side" && mixerLayout !== "horizontal") mixerLayout = "side";
        let timelineMode = loadPref("pb_remote_timeline_mode", "waveform");
        if (timelineMode !== "waveform" && timelineMode !== "progress" && timelineMode !== "none") timelineMode = "waveform";

        const DEFAULT_SETLIST_W = 250;
        const DEFAULT_MIXER_W = 350;
        const DEFAULT_DOCK_H = 310;

        function loadPref(key, fallback) {
          try {
            const v = localStorage.getItem(key);
            return v === null ? fallback : v;
          } catch (_) {
            return fallback;
          }
        }
        function savePref(key, val) {
          try { localStorage.setItem(key, String(val)); } catch (_) {}
        }
        function removePref(key) {
          try { localStorage.removeItem(key); } catch (_) {}
        }

        function applyLayoutPrefs() {
          const root = document.documentElement;
          const sw = parseInt(loadPref("pb_remote_setlist_w", String(DEFAULT_SETLIST_W)), 10);
          const mw = parseInt(loadPref("pb_remote_mixer_w", String(DEFAULT_MIXER_W)), 10);
          const dhRaw = loadPref("pb_remote_dock_h", "");
          const dh = parseInt(dhRaw, 10);
          root.style.setProperty("--setlist-w", (isFinite(sw) ? Math.max(180, Math.min(540, sw)) : DEFAULT_SETLIST_W) + "px");
          root.style.setProperty("--mixer-w", (isFinite(mw) ? Math.max(260, Math.min(680, mw)) : DEFAULT_MIXER_W) + "px");
          const main = document.getElementById("mainUI");
          if (dhRaw !== "" && isFinite(dh)) {
            root.style.setProperty("--dock-h", Math.max(200, Math.min(560, dh)) + "px");
            main.classList.add("custom-dock-h");
          } else {
            root.style.setProperty("--dock-h", DEFAULT_DOCK_H + "px");
            main.classList.remove("custom-dock-h");
          }
        }

        function syncMixerChrome() {
          const main = document.getElementById("mainUI");
          const colMixer = document.getElementById("colMixer");
          const tabTracks = document.getElementById("mixerTabTracks");
          const tabBuses = document.getElementById("mixerTabBuses");
          const layoutBtn = document.getElementById("mixerLayoutBtn");
          const sideMaster = document.getElementById("sideMasterRow");

          const isHoriz = (mixerLayout === "horizontal");
          main.classList.toggle("layout-horizontal", isHoriz);
          main.classList.toggle("layout-side", !isHoriz);
          colMixer.classList.toggle("is-horizontal", isHoriz);
          sideMaster.style.display = isHoriz ? "none" : "";

          tabTracks.className = "seg-tab" + (mixerTab === "tracks" ? " active" : "");
          tabBuses.className = "seg-tab" + (mixerTab === "buses" ? " active" : "");
          layoutBtn.className = "layout-btn" + (isHoriz ? " active" : "");
          layoutBtn.textContent = isHoriz ? "Side View" : "Horizontal";
        }

        function syncTimelineChrome() {
          const card = document.getElementById("timelineCard");
          const waveWrap = document.getElementById("waveformWrap");
          const progWrap = document.getElementById("progressWrap");
          const sel = document.getElementById("timelineModeSelect");
          if (sel) sel.value = timelineMode;
          if (timelineMode === "none") {
            card.style.display = "none";
          } else {
            card.style.display = "";
            waveWrap.style.display = (timelineMode === "waveform") ? "" : "none";
            progWrap.style.display = (timelineMode === "progress") ? "" : "none";
            if (timelineMode === "waveform") {
              requestAnimationFrame(() => drawWaveform(currentDisplayTime()));
            } else {
              updateProgressUI(currentDisplayTime());
            }
          }
        }

        function fmt(t) {
          t = Math.max(0, Math.floor(t || 0));
          return Math.floor(t / 60) + ":" + String(t % 60).padStart(2, "0");
        }
        function fmtPan(p) {
          const n = Math.round((p || 0) * 100);
          if (Math.abs(n) < 3) return "C";
          return (n < 0 ? "L" : "R") + Math.abs(n);
        }
        function fmtLevelPct(v) {
          const val = Math.max(0, Math.min(1, v || 0));
          if (val <= 0.01) return "-inf";
          if (Math.abs(val - 0.80) < 0.015) return "0.0 dB";
          return Math.round(val * 100) + "%";
        }
        function throttledSlider(id, fn) {
          const now = Date.now();
          if (now - lastSliderAt >= 35) {
            lastSliderAt = now;
            fn();
          }
        }
        function sendCmd(obj) {
          if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj));
        }
        function submitAuth() {
          const pw = document.getElementById("pwInput").value || "";
          sendCmd({ type: "auth", password: pw });
        }
        function normKey(k) {
          const map = { "C#":"Db", "D#":"Eb", "F#":"Gb", "G#":"Ab", "A#":"Bb" };
          return map[k] || k;
        }
        function makeHVuPair() {
          const wrap = document.createElement("div");
          wrap.className = "vu-hpair";
          const barL = document.createElement("div");
          barL.className = "vu-hbar";
          const maskL = document.createElement("div");
          maskL.className = "vu-hmask";
          barL.appendChild(maskL);
          const barR = document.createElement("div");
          barR.className = "vu-hbar";
          const maskR = document.createElement("div");
          maskR.className = "vu-hmask";
          barR.appendChild(maskR);
          wrap.appendChild(barL);
          wrap.appendChild(barR);
          return { wrap, maskL, maskR };
        }
        function setHMask(el, pct) {
          if (!el) return;
          const p = Math.max(0, Math.min(100, pct || 0));
          el.style.transform = "scaleX(" + ((100 - p) / 100).toFixed(3) + ")";
        }
        function setVMask(el, pct) {
          if (!el) return;
          const p = Math.max(0, Math.min(100, pct || 0));
          el.style.transform = "scaleY(" + ((100 - p) / 100).toFixed(3) + ")";
        }

        // Cap-only relative horizontal fader (volume or pan) to eliminate accidental level changes
        function createHorizontalFader(opts) {
          const min = typeof opts.min === "number" ? opts.min : 0;
          const max = typeof opts.max === "number" ? opts.max : 1;
          const isBipolar = !!opts.bipolar;
          const capWidth = opts.compactPan ? 11 : (isBipolar ? 13 : 16);

          const well = document.createElement("div");
          well.className = "hfader-well" + (opts.extraClass ? " " + opts.extraClass : "");
          if (opts.id) well.id = opts.id;

          const track = document.createElement("div");
          track.className = "hfader-track";
          const fill = document.createElement("div");
          fill.className = "hfader-fill";
          track.appendChild(fill);

          if (!isBipolar) {
            const tick = document.createElement("div");
            tick.className = "hfader-tick";
            tick.style.left = "80%";
            track.appendChild(tick);
          } else {
            const centerTick = document.createElement("div");
            centerTick.className = "hfader-tick";
            centerTick.style.left = "50%";
            track.appendChild(centerTick);
          }

          const cap = document.createElement("div");
          cap.className = "hfader-cap";
          const capLine = document.createElement("div");
          capLine.className = "hfader-cap-line";
          cap.appendChild(capLine);

          well.appendChild(track);
          well.appendChild(cap);

          let currentVal = typeof opts.initialValue === "number" ? opts.initialValue : (isBipolar ? 0 : 0.8);

          function setValue(val) {
            const clamped = Math.max(min, Math.min(max, val || 0));
            currentVal = clamped;
            const norm = (clamped - min) / (max - min);
            cap.style.setProperty("--p", String(norm));
            if (isBipolar) {
              const leftPct = Math.min(0.5, norm) * 100;
              const widthPct = Math.abs(norm - 0.5) * 100;
              fill.style.left = leftPct.toFixed(2) + "%";
              fill.style.width = widthPct.toFixed(2) + "%";
            } else {
              fill.style.left = "0%";
              fill.style.width = (norm * 100).toFixed(2) + "%";
            }
            if (opts.onUiUpdate) opts.onUiUpdate(clamped);
          }
          setValue(currentVal);

          let drag = null;
          cap.addEventListener("pointerdown", (ev) => {
            ev.preventDefault();
            ev.stopPropagation();
            try { cap.setPointerCapture(ev.pointerId); } catch (_) {}
            activeSlider = opts.sliderKey;
            cap.classList.add("grabbing");
            drag = { pointerId: ev.pointerId, startX: ev.clientX, startVal: currentVal, hasMoved: false };
          });
          cap.addEventListener("pointermove", (ev) => {
            if (!drag || drag.pointerId !== ev.pointerId) return;
            const dx = ev.clientX - drag.startX;
            if (!drag.hasMoved) {
              if (Math.abs(dx) < 4) return;
              drag.hasMoved = true;
            }
            const rect = well.getBoundingClientRect();
            const travel = Math.max(12, rect.width - capWidth);
            const raw = drag.startVal + (dx / travel) * (max - min);
            const step = isBipolar ? 0.02 : 0.005;
            const snapped = Math.max(min, Math.min(max, Math.round(raw / step) * step));
            setValue(snapped);
            throttledSlider(opts.sliderKey, () => opts.onInput(snapped));
          });
          cap.addEventListener("pointerup", (ev) => {
            if (!drag || drag.pointerId !== ev.pointerId) return;
            const moved = drag.hasMoved;
            drag = null;
            cap.classList.remove("grabbing");
            activeSlider = null;
            if (!moved) {
              const prevTap = (tapState[opts.sliderKey] && tapState[opts.sliderKey].lastTap) || 0;
              const now = Date.now();
              if (now - prevTap < 340) {
                tapState[opts.sliderKey] = { lastTap: 0 };
                setValue(opts.resetValue);
                opts.onReset();
              } else {
                tapState[opts.sliderKey] = { lastTap: now };
              }
              return;
            }
            opts.onCommit(currentVal);
          });
          cap.addEventListener("pointercancel", () => {
            const moved = drag && drag.hasMoved;
            drag = null;
            cap.classList.remove("grabbing");
            activeSlider = null;
            if (moved && opts.onCancel) opts.onCancel();
          });

          return { well, cap, setValue, getValue: () => currentVal };
        }

        // Cap-only relative vertical fader for Horizontal Console Mode
        function createVerticalFaderWell(opts) {
          const well = document.createElement("div");
          well.className = "vfader-well";
          const groove = document.createElement("div");
          groove.className = "vfader-groove";
          const unity = document.createElement("div");
          unity.className = "vfader-unity";

          const barL = document.createElement("div");
          barL.className = "vu-vbar left";
          const vuMaskL = document.createElement("div");
          vuMaskL.className = "vu-vmask";
          barL.appendChild(vuMaskL);

          const barR = document.createElement("div");
          barR.className = "vu-vbar right";
          const vuMaskR = document.createElement("div");
          vuMaskR.className = "vu-vmask";
          barR.appendChild(vuMaskR);

          const cap = document.createElement("div");
          cap.className = "vfader-cap" + (opts.capClass ? " " + opts.capClass : "");
          const capLine = document.createElement("div");
          capLine.className = "vfader-cap-line";
          cap.appendChild(capLine);

          well.appendChild(groove);
          well.appendChild(unity);
          well.appendChild(barL);
          well.appendChild(barR);
          well.appendChild(cap);

          let currentVal = typeof opts.initialValue === "number" ? opts.initialValue : 0.8;

          function setValue(val) {
            const v = Math.max(0, Math.min(1, val || 0));
            currentVal = v;
            cap.style.setProperty("--v", String(v));
            if (opts.onUiUpdate) opts.onUiUpdate(v);
          }
          setValue(currentVal);

          let drag = null;
          cap.addEventListener("pointerdown", (ev) => {
            ev.preventDefault();
            ev.stopPropagation();
            try { cap.setPointerCapture(ev.pointerId); } catch (_) {}
            activeSlider = opts.sliderKey;
            cap.classList.add("grabbing");
            drag = { pointerId: ev.pointerId, startY: ev.clientY, startVal: currentVal, hasMoved: false };
          });
          cap.addEventListener("pointermove", (ev) => {
            if (!drag || drag.pointerId !== ev.pointerId) return;
            const dy = drag.startY - ev.clientY;
            if (!drag.hasMoved) {
              if (Math.abs(dy) < 4) return;
              drag.hasMoved = true;
            }
            const rect = well.getBoundingClientRect();
            const capH = 22;
            const travel = Math.max(10, rect.height - capH);
            const raw = drag.startVal + (dy / travel);
            const v = Math.max(0, Math.min(1, Math.round(raw * 200) / 200));
            setValue(v);
            throttledSlider(opts.sliderKey, () => opts.onInput(v));
          });
          cap.addEventListener("pointerup", (ev) => {
            if (!drag || drag.pointerId !== ev.pointerId) return;
            const moved = drag.hasMoved;
            drag = null;
            cap.classList.remove("grabbing");
            activeSlider = null;
            if (!moved) {
              const prevTap = (tapState[opts.sliderKey] && tapState[opts.sliderKey].lastTap) || 0;
              const now = Date.now();
              if (now - prevTap < 340) {
                tapState[opts.sliderKey] = { lastTap: 0 };
                setValue(opts.resetValue);
                opts.onReset();
              } else {
                tapState[opts.sliderKey] = { lastTap: now };
              }
              return;
            }
            opts.onCommit(currentVal);
          });
          cap.addEventListener("pointercancel", () => {
            const moved = drag && drag.hasMoved;
            drag = null;
            cap.classList.remove("grabbing");
            activeSlider = null;
            if (moved && opts.onCancel) opts.onCancel();
          });

          return { well, cap, vuMaskL, vuMaskR, setValue };
        }

        function resetMasterFader() {
          if (masterHFader) masterHFader.setValue(defaultFaderLevel);
          if (consoleMasterEntry) consoleMasterEntry.setValue(defaultFaderLevel);
          sendCmd({ type: "setMasterVolume", volume: defaultFaderLevel });
        }
        function resetPadFader() {
          if (padVolHFader) padVolHFader.setValue(defaultFaderLevel);
          sendCmd({ type: "setPadVolume", volume: defaultFaderLevel });
        }
        function resetPadPan() {
          if (padPanHFader) padPanHFader.setValue(0);
          document.getElementById("padPanVal").textContent = "C";
          sendCmd({ type: "setPadPan", pan: 0 });
          sendCmd({ type: "commitPadMix" });
        }
        function resetTrackFader(id, setUiFn) {
          if (setUiFn) setUiFn(defaultFaderLevel);
          sendCmd({ type: "setTrackVolume", trackId: id, volume: defaultFaderLevel });
          sendCmd({ type: "commitTrackMix" });
        }
        function resetTrackPan(id, setUiFn, labelEl) {
          if (setUiFn) setUiFn(0);
          if (labelEl) labelEl.textContent = "C";
          sendCmd({ type: "setTrackPan", trackId: id, pan: 0 });
          sendCmd({ type: "commitTrackMix" });
        }
        function resetBusFader(id, setUiFn) {
          if (setUiFn) setUiFn(0.80);
          sendCmd({ type: "setBusVolume", busId: id, volume: 0.80 });
          sendCmd({ type: "commitBusMix", busId: id });
        }

        function currentDisplayTime() {
          if (!lastState) return 0;
          const dur = Math.max(0, lastState.duration || 0);
          if (!lastState.isPlaying) return Math.min(dur || lastState.currentTime || 0, lastState.currentTime || 0);
          const elapsed = (performance.now() - playheadBasePerf) / 1000;
          const t = playheadBaseTime + Math.max(0, elapsed);
          return dur > 0 ? Math.min(dur, t) : t;
        }

        function updateProgressUI(curTime) {
          const s = lastState;
          if (!s) return;
          const dur = Math.max(0.01, s.duration || 0);
          const pct = Math.max(0, Math.min(100, (curTime / dur) * 100));
          const el = document.getElementById("progElapsed");
          const rem = document.getElementById("progRem");
          const fill = document.getElementById("progFill");
          if (el) el.textContent = fmt(curTime);
          if (rem) rem.textContent = "-" + fmt(Math.max(0, (s.duration || 0) - curTime));
          if (fill) fill.style.width = pct.toFixed(2) + "%";
        }

        function drawWaveform(curTime) {
          const canvas = document.getElementById("waveformCanvas");
          if (!canvas || timelineMode !== "waveform") return;
          const rect = canvas.getBoundingClientRect();
          const w = Math.max(120, Math.floor(rect.width));
          const h = Math.max(40, Math.floor(rect.height));
          const dpr = window.devicePixelRatio || 1;
          if (canvas.width !== Math.floor(w * dpr) || canvas.height !== Math.floor(h * dpr)) {
            canvas.width = Math.floor(w * dpr);
            canvas.height = Math.floor(h * dpr);
          }
          const ctx = canvas.getContext("2d");
          ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
          ctx.clearRect(0, 0, w, h);

          const s = lastState;
          if (!s) return;
          const dur = Math.max(0.01, s.duration || (lastWaveform && lastWaveform.duration) || 0.01);
          const sections = s.sections || [];

          for (let i = 0; i < sections.length; i++) {
            const sec = sections[i];
            const x1 = Math.max(0, Math.min(w, (sec.startTime / dur) * w));
            const x2 = Math.max(x1, Math.min(w, (sec.endTime / dur) * w));
            const col = sec.colorHex || "#3aa0ff";
            ctx.save();
            ctx.globalAlpha = sec.isActive ? 0.24 : (sec.isQueued ? 0.22 : 0.14);
            ctx.fillStyle = col;
            ctx.fillRect(x1, 0, Math.max(1, x2 - x1), h);
            ctx.restore();

            ctx.strokeStyle = "rgba(255,255,255,0.16)";
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.moveTo(x1, 0);
            ctx.lineTo(x1, h);
            ctx.stroke();

            if (x2 - x1 > 34) {
              ctx.fillStyle = sec.isActive ? "#f3f5f8" : "rgba(243,245,248,0.75)";
              ctx.font = "700 10px -apple-system, BlinkMacSystemFont, sans-serif";
              ctx.fillText(sec.name || "", x1 + 4, 12);
            }
          }

          const playX = Math.max(0, Math.min(w, (curTime / dur) * w));
          const peaks = (lastWaveform && lastWaveform.peaks) || [];
          const midY = h * 0.62;
          const ampScale = h * 0.32;

          if (peaks.length > 0) {
            const step = w / peaks.length;
            const barW = Math.max(1, step - 0.8);
            for (let i = 0; i < peaks.length; i++) {
              const x = i * step;
              const v = Math.max(0, Math.min(100, peaks[i])) / 100;
              const bh = Math.max(1.2, v * ampScale);
              ctx.fillStyle = x <= playX ? "#3aa0ff" : "rgba(139,147,166,0.52)";
              ctx.fillRect(x, midY - bh, barW, bh * 2);
            }
          }

          ctx.strokeStyle = "#f3f5f8";
          ctx.lineWidth = 1.8;
          ctx.beginPath();
          ctx.moveTo(playX, 0);
          ctx.lineTo(playX, h);
          ctx.stroke();

          const remEl = document.getElementById("waveRemTime");
          if (remEl) remEl.textContent = "-" + fmt(Math.max(0, (s.duration || 0) - curTime));
        }

        function handleTimelineTap(ratio) {
          if (!lastState) return;
          const dur = Math.max(0, lastState.duration || 0);
          if (dur <= 0) return;
          const targetSec = Math.max(0, Math.min(dur, ratio * dur));
          if (lastState.isPlaying) {
            const sections = lastState.sections || [];
            const idx = sections.findIndex(sec => targetSec >= sec.startTime && targetSec < sec.endTime);
            if (idx >= 0) sendCmd({ type: "jumpSection", sectionIndex: idx });
          } else {
            sendCmd({ type: "seek", time: targetSec });
          }
        }

        function stopPlayheadLoop() {
          if (rafId !== null) {
            cancelAnimationFrame(rafId);
            rafId = null;
          }
        }
        function startPlayheadLoop() {
          if (rafId !== null) return;
          function step() {
            if (!lastState || !lastState.isPlaying || timelineMode === "none") {
              rafId = null;
              return;
            }
            const t = currentDisplayTime();
            const metaEl = document.getElementById("songMeta");
            if (metaEl) {
              metaEl.textContent = `${Math.round(lastState.bpm)} BPM • Key ${lastState.musicalKey} • ${fmt(t)} / ${fmt(lastState.duration)}`;
            }
            if (timelineMode === "waveform") {
              drawWaveform(t);
            } else if (timelineMode === "progress") {
              updateProgressUI(t);
            }
            rafId = requestAnimationFrame(step);
          }
          rafId = requestAnimationFrame(step);
        }

        function bindSplitter(id, axis, cssVar, lsKey, defaultVal, minVal, maxFn, onCommitExtra, onDoubleReset) {
          const el = document.getElementById(id);
          if (!el) return;
          let state = null;
          el.addEventListener("pointerdown", (ev) => {
            ev.preventDefault();
            try { el.setPointerCapture(ev.pointerId); } catch (_) {}
            el.classList.add("dragging");
            document.body.style.userSelect = "none";
            let cur = parseFloat(getComputedStyle(document.documentElement).getPropertyValue(cssVar)) || defaultVal;
            if (id === "splitterBottom" && !document.getElementById("mainUI").classList.contains("custom-dock-h")) {
              const colMixer = document.getElementById("colMixer");
              cur = (colMixer && colMixer.offsetHeight) ? colMixer.offsetHeight : defaultVal;
              document.documentElement.style.setProperty(cssVar, cur + "px");
              document.getElementById("mainUI").classList.add("custom-dock-h");
            }
            state = { pointerId: ev.pointerId, startPos: axis === "x" ? ev.clientX : ev.clientY, startSize: cur };
          });
          el.addEventListener("pointermove", (ev) => {
            if (!state || state.pointerId !== ev.pointerId) return;
            const delta = (axis === "x" ? ev.clientX : ev.clientY) - state.startPos;
            const signedDelta = (id === "splitterLeft") ? delta : -delta;
            const maxVal = maxFn();
            const next = Math.round(Math.max(minVal, Math.min(maxVal, state.startSize + signedDelta)));
            document.documentElement.style.setProperty(cssVar, next + "px");
            state.current = next;
          });
          function finish(ev) {
            if (!state || state.pointerId !== ev.pointerId) return;
            el.classList.remove("dragging");
            document.body.style.userSelect = "";
            if (typeof state.current === "number") {
              savePref(lsKey, state.current);
              if (onCommitExtra) onCommitExtra();
            }
            state = null;
          }
          el.addEventListener("pointerup", finish);
          el.addEventListener("pointercancel", finish);
          el.addEventListener("dblclick", () => {
            document.documentElement.style.setProperty(cssVar, defaultVal + "px");
            removePref(lsKey);
            if (onDoubleReset) onDoubleReset();
          });
        }

        function bindStaticControls() {
          applyLayoutPrefs();
          syncMixerChrome();
          syncTimelineChrome();

          masterHFader = createHorizontalFader({
            id: "masterVol",
            sliderKey: "__master__",
            min: 0, max: 1,
            initialValue: 0.80,
            resetValue: defaultFaderLevel,
            extraClass: "master-fader",
            onInput: (v) => sendCmd({ type: "setMasterVolume", volume: v }),
            onCommit: (v) => sendCmd({ type: "setMasterVolume", volume: v }),
            onReset: () => sendCmd({ type: "setMasterVolume", volume: defaultFaderLevel })
          });
          document.getElementById("masterVolSlot").replaceChildren(masterHFader.well);

          padVolHFader = createHorizontalFader({
            id: "padVol",
            sliderKey: "__pad__",
            min: 0, max: 1,
            initialValue: 0.80,
            resetValue: defaultFaderLevel,
            onInput: (v) => sendCmd({ type: "setPadVolume", volume: v }),
            onCommit: (v) => sendCmd({ type: "setPadVolume", volume: v }),
            onReset: () => sendCmd({ type: "setPadVolume", volume: defaultFaderLevel })
          });
          document.getElementById("padVolSlot").replaceChildren(padVolHFader.well);

          padPanHFader = createHorizontalFader({
            id: "padPan",
            sliderKey: "__padPan__",
            min: -1, max: 1,
            bipolar: true,
            initialValue: 0,
            resetValue: 0,
            extraClass: "pan-fader",
            onUiUpdate: (p) => { document.getElementById("padPanVal").textContent = fmtPan(p); },
            onInput: (p) => sendCmd({ type: "setPadPan", pan: p }),
            onCommit: (p) => {
              sendCmd({ type: "setPadPan", pan: p });
              sendCmd({ type: "commitPadMix" });
            },
            onReset: () => {
              sendCmd({ type: "setPadPan", pan: 0 });
              sendCmd({ type: "commitPadMix" });
            },
            onCancel: () => sendCmd({ type: "commitPadMix" })
          });
          document.getElementById("padPanSlot").replaceChildren(padPanHFader.well);

          const pwInput = document.getElementById("pwInput");
          pwInput.addEventListener("keydown", (event) => {
            if (event.key === "Enter") submitAuth();
          });
          document.getElementById("unlockBtn").addEventListener("click", submitAuth);

          document.getElementById("timelineModeSelect").addEventListener("change", (ev) => {
            timelineMode = ev.target.value;
            savePref("pb_remote_timeline_mode", timelineMode);
            syncTimelineChrome();
            if (lastState && lastState.isPlaying && timelineMode !== "none") startPlayheadLoop();
            else stopPlayheadLoop();
          });

          document.getElementById("waveformCanvas").addEventListener("click", (ev) => {
            const rect = ev.currentTarget.getBoundingClientRect();
            if (rect.width <= 0) return;
            handleTimelineTap((ev.clientX - rect.left) / rect.width);
          });
          document.getElementById("progressBarTrack").addEventListener("click", (ev) => {
            const rect = ev.currentTarget.getBoundingClientRect();
            if (rect.width <= 0) return;
            handleTimelineTap((ev.clientX - rect.left) / rect.width);
          });

          document.getElementById("playBtn").addEventListener("click", () => sendCmd({ type: "playPause" }));
          document.getElementById("rtzBtn").addEventListener("click", () => sendCmd({ type: "rtz" }));
          document.getElementById("fadeBtn").addEventListener("click", () => sendCmd({ type: "fade" }));
          document.getElementById("prevSongBtn").addEventListener("click", () => sendCmd({ type: "prevSong" }));
          document.getElementById("nextSongBtn").addEventListener("click", () => sendCmd({ type: "nextSong" }));
          document.getElementById("loop1xBtn").addEventListener("click", () => sendCmd({ type: "toggleSingleLoop" }));
          document.getElementById("loopInfBtn").addEventListener("click", () => sendCmd({ type: "toggleInfiniteLoop" }));

          document.getElementById("padLinkBtn").addEventListener("click", () => sendCmd({ type: "togglePadLink" }));
          document.getElementById("padFireBtn").addEventListener("click", () => sendCmd({ type: "togglePad" }));
          document.getElementById("padPackSelect").addEventListener("change", (ev) => {
            sendCmd({ type: "setPadPack", padPackId: ev.target.value });
          });
          document.getElementById("padMuteBtn").addEventListener("click", () => sendCmd({ type: "togglePadMute" }));
          document.getElementById("padSoloBtn").addEventListener("click", () => sendCmd({ type: "togglePadSolo" }));

          document.getElementById("mixerTabTracks").addEventListener("click", () => {
            if (mixerTab === "tracks") return;
            mixerTab = "tracks";
            savePref("pb_remote_mixer_tab", mixerTab);
            syncMixerChrome();
            if (lastState) renderMixer(lastState);
          });
          document.getElementById("mixerTabBuses").addEventListener("click", () => {
            if (mixerTab === "buses") return;
            mixerTab = "buses";
            savePref("pb_remote_mixer_tab", mixerTab);
            syncMixerChrome();
            if (lastState) renderMixer(lastState);
          });
          document.getElementById("mixerLayoutBtn").addEventListener("click", () => {
            mixerLayout = (mixerLayout === "horizontal") ? "side" : "horizontal";
            savePref("pb_remote_mixer_layout", mixerLayout);
            syncMixerChrome();
            if (lastState) renderMixer(lastState);
          });

          bindSplitter(
            "splitterLeft", "x", "--setlist-w", "pb_remote_setlist_w", DEFAULT_SETLIST_W, 180,
            () => {
              const total = document.getElementById("mainUI").clientWidth || window.innerWidth;
              const other = (mixerLayout === "side")
                ? (parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--mixer-w")) || DEFAULT_MIXER_W)
                : 0;
              return Math.max(180, Math.min(540, total - other - 300));
            }
          );
          bindSplitter(
            "splitterRight", "x", "--mixer-w", "pb_remote_mixer_w", DEFAULT_MIXER_W, 260,
            () => {
              const total = document.getElementById("mainUI").clientWidth || window.innerWidth;
              const other = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--setlist-w")) || DEFAULT_SETLIST_W;
              return Math.max(260, Math.min(680, total - other - 300));
            }
          );
          bindSplitter(
            "splitterBottom", "y", "--dock-h", "pb_remote_dock_h", DEFAULT_DOCK_H, 200,
            () => {
              const totalH = document.getElementById("mainUI").clientHeight || window.innerHeight;
              return Math.max(200, Math.min(560, totalH - 190));
            },
            null,
            () => { document.getElementById("mainUI").classList.remove("custom-dock-h"); }
          );

          window.addEventListener("resize", () => {
            if (timelineMode === "waveform") drawWaveform(currentDisplayTime());
          });
        }

        function connect() {
          const proto = location.protocol === "https:" ? "wss://" : "ws://";
          ws = new WebSocket(proto + location.host + "/ws");
          ws.onopen = () => {
            const el = document.getElementById("conn");
            el.textContent = "Connected";
            el.className = "badge ok";
          };
          ws.onclose = () => {
            const el = document.getElementById("conn");
            el.textContent = "Reconnecting...";
            el.className = "badge";
            stopPlayheadLoop();
            setTimeout(connect, 1500);
          };
          ws.onmessage = (ev) => {
            const msg = JSON.parse(ev.data);
            if (msg.type === "authRequired") {
              document.getElementById("authCard").style.display = "block";
              document.getElementById("mainUI").style.display = "none";
              document.getElementById("authErr").textContent = "";
              return;
            }
            if (msg.type === "authFailed") {
              document.getElementById("authCard").style.display = "block";
              document.getElementById("mainUI").style.display = "none";
              document.getElementById("authErr").textContent = msg.locked
                ? "Too many attempts. Try again in 30s."
                : "Incorrect password.";
              return;
            }
            if (msg.type === "meters") {
              lastMeters = msg;
              applyMeters(msg);
              return;
            }
            if (msg.type === "waveform") {
              lastWaveform = msg;
              if (timelineMode === "waveform") drawWaveform(currentDisplayTime());
              return;
            }
            document.getElementById("authCard").style.display = "none";
            document.getElementById("mainUI").style.display = "";
            lastState = msg;
            playheadBaseTime = msg.currentTime || 0;
            playheadBasePerf = performance.now();
            render(msg);
          };
        }

        function applyMeters(m) {
          if (!m) return;
          const isHoriz = (mixerLayout === "horizontal");
          const mst = m.master || [0, 0];
          setHMask(document.getElementById("masterMeterL"), mst[0]);
          setHMask(document.getElementById("masterMeterR"), mst[1]);
          if (consoleMasterEntry) {
            setVMask(consoleMasterEntry.vuMaskL, mst[0]);
            setVMask(consoleMasterEntry.vuMaskR, mst[1]);
          }

          const pad = m.pad || [0, 0];
          setHMask(document.getElementById("padMeterL"), pad[0]);
          setHMask(document.getElementById("padMeterR"), pad[1]);

          const tMap = m.tracks || {};
          for (const [id, entry] of trackDomById.entries()) {
            const pair = tMap[id] || [0, 0];
            if (isHoriz) {
              setVMask(entry.vuMaskL, pair[0]);
              setVMask(entry.vuMaskR, pair[1]);
            } else {
              setHMask(entry.vuMaskL, pair[0]);
              setHMask(entry.vuMaskR, pair[1]);
            }
          }

          const bMap = m.buses || {};
          for (const [id, entry] of busDomById.entries()) {
            const pair = bMap[id] || [0, 0];
            if (isHoriz) {
              setVMask(entry.vuMaskL, pair[0]);
              setVMask(entry.vuMaskR, pair[1]);
            } else {
              setHMask(entry.vuMaskL, pair[0]);
              setHMask(entry.vuMaskR, pair[1]);
            }
          }
        }

        function stripCapClassForTrack(t) {
          const role = (t.role || "").toLowerCase();
          if (role === "click") return "click";
          if (role === "guide") return "guide";
          if (role === "pad") return "pad";
          return "";
        }
        function stripCapClassForBus(b) {
          const n = (b.name || "").toLowerCase();
          if (n === "click") return "click";
          if (n === "guide") return "guide";
          if (n === "pad") return "pad";
          return "";
        }

        function buildSideTrackRow(t) {
          const item = document.createElement("div");
          item.className = "track-item";
          const row = document.createElement("div");
          row.className = "track-row";

          const nameWrap = document.createElement("div");
          nameWrap.className = "track-name-wrap";
          const nameEl = document.createElement("div");
          nameEl.className = "track-name";
          nameEl.textContent = t.shortName || t.name || "";
          nameEl.title = t.name || "";
          nameWrap.appendChild(nameEl);

          const fmCol = document.createElement("div");
          fmCol.className = "fader-meter-col";
          const volKey = "trkVol:" + t.id;
          const volFader = createHorizontalFader({
            sliderKey: volKey,
            min: 0, max: 1,
            initialValue: t.volume,
            resetValue: defaultFaderLevel,
            onInput: (v) => sendCmd({ type: "setTrackVolume", trackId: t.id, volume: v }),
            onCommit: (v) => {
              sendCmd({ type: "setTrackVolume", trackId: t.id, volume: v });
              sendCmd({ type: "commitTrackMix" });
            },
            onReset: () => resetTrackFader(t.id, null),
            onCancel: () => sendCmd({ type: "commitTrackMix" })
          });

          const vu = makeHVuPair();
          fmCol.appendChild(volFader.well);
          fmCol.appendChild(vu.wrap);

          const muteBtn = document.createElement("button");
          muteBtn.className = "mini-btn" + (t.isMuted ? " muted" : "");
          muteBtn.textContent = "M";
          muteBtn.addEventListener("click", () => sendCmd({ type: "toggleMute", trackId: t.id }));

          const soloBtn = document.createElement("button");
          soloBtn.className = "mini-btn" + (t.isSoloed ? " soloed" : "");
          soloBtn.textContent = "S";
          soloBtn.addEventListener("click", () => sendCmd({ type: "toggleSolo", trackId: t.id }));

          row.appendChild(nameWrap);
          row.appendChild(fmCol);
          row.appendChild(muteBtn);
          row.appendChild(soloBtn);

          const panRow = document.createElement("div");
          panRow.className = "pan-subrow";
          const panLabel = document.createElement("div");
          panLabel.className = "pan-label";
          panLabel.textContent = "PAN";
          const panVal = document.createElement("div");
          panVal.className = "pan-val";
          panVal.textContent = fmtPan(t.pan);
          const panKey = "trkPan:" + t.id;
          const panFader = createHorizontalFader({
            sliderKey: panKey,
            min: -1, max: 1,
            bipolar: true,
            initialValue: typeof t.pan === "number" ? t.pan : 0,
            resetValue: 0,
            extraClass: "pan-fader",
            onUiUpdate: (p) => { panVal.textContent = fmtPan(p); },
            onInput: (p) => sendCmd({ type: "setTrackPan", trackId: t.id, pan: p }),
            onCommit: (p) => {
              sendCmd({ type: "setTrackPan", trackId: t.id, pan: p });
              sendCmd({ type: "commitTrackMix" });
            },
            onReset: () => resetTrackPan(t.id, null, panVal),
            onCancel: () => sendCmd({ type: "commitTrackMix" })
          });
          panRow.appendChild(panLabel);
          panRow.appendChild(panFader.well);
          panRow.appendChild(panVal);

          item.appendChild(row);
          item.appendChild(panRow);

          trackDomById.set(t.id, {
            nameEl, panVal, muteBtn, soloBtn,
            vuMaskL: vu.maskL, vuMaskR: vu.maskR,
            setVolume: volFader.setValue,
            setPan: panFader.setValue
          });
          return item;
        }

        function buildSideBusRow(b) {
          const item = document.createElement("div");
          item.className = "track-item";
          const row = document.createElement("div");
          row.className = "track-row";

          const nameWrap = document.createElement("div");
          nameWrap.className = "track-name-wrap";
          const nameEl = document.createElement("div");
          nameEl.className = "track-name";
          nameEl.textContent = b.shortName || b.name || "";
          nameEl.title = b.name || "";
          const outEl = document.createElement("div");
          outEl.className = "bus-out";
          outEl.textContent = b.physicalOutputChannel || "";
          nameWrap.appendChild(nameEl);
          nameWrap.appendChild(outEl);

          const fmCol = document.createElement("div");
          fmCol.className = "fader-meter-col";
          const busKey = "busVol:" + b.id;
          const volFader = createHorizontalFader({
            sliderKey: busKey,
            min: 0, max: 1,
            initialValue: b.volume,
            resetValue: 0.80,
            onInput: (v) => sendCmd({ type: "setBusVolume", busId: b.id, volume: v }),
            onCommit: (v) => {
              sendCmd({ type: "setBusVolume", busId: b.id, volume: v });
              sendCmd({ type: "commitBusMix", busId: b.id });
            },
            onReset: () => resetBusFader(b.id, null),
            onCancel: () => sendCmd({ type: "commitBusMix", busId: b.id })
          });

          const vu = makeHVuPair();
          fmCol.appendChild(volFader.well);
          fmCol.appendChild(vu.wrap);

          const muteBtn = document.createElement("button");
          muteBtn.className = "mini-btn" + (b.isMuted ? " muted" : "");
          muteBtn.textContent = "M";
          muteBtn.addEventListener("click", () => sendCmd({ type: "toggleBusMute", busId: b.id }));

          const soloBtn = document.createElement("button");
          soloBtn.className = "mini-btn" + (b.isSoloed ? " soloed" : (b.isSoloSafe ? " solo-safe" : ""));
          soloBtn.textContent = "S";
          soloBtn.addEventListener("click", () => sendCmd({ type: "toggleBusSolo", busId: b.id }));

          row.appendChild(nameWrap);
          row.appendChild(fmCol);
          row.appendChild(muteBtn);
          row.appendChild(soloBtn);
          item.appendChild(row);

          busDomById.set(b.id, {
            nameEl, outEl, muteBtn, soloBtn,
            vuMaskL: vu.maskL, vuMaskR: vu.maskR,
            setVolume: volFader.setValue
          });
          return item;
        }

        function buildConsoleMasterStrip(s) {
          const strip = document.createElement("div");
          strip.className = "console-strip master-strip";

          const badge = document.createElement("div");
          badge.className = "strip-badge";
          badge.textContent = "MASTER";

          const levelEl = document.createElement("div");
          levelEl.className = "strip-submeta";
          levelEl.textContent = fmtLevelPct(s.masterVolume);

          const fader = createVerticalFaderWell({
            sliderKey: "__master__",
            initialValue: s.masterVolume,
            resetValue: defaultFaderLevel,
            capClass: "master",
            onUiUpdate: (v) => { levelEl.textContent = fmtLevelPct(v); },
            onInput: (v) => sendCmd({ type: "setMasterVolume", volume: v }),
            onCommit: (v) => sendCmd({ type: "setMasterVolume", volume: v }),
            onReset: () => sendCmd({ type: "setMasterVolume", volume: defaultFaderLevel }),
            onCancel: () => {}
          });

          const nameEl = document.createElement("div");
          nameEl.className = "strip-name";
          nameEl.textContent = "MASTER";

          strip.appendChild(badge);
          strip.appendChild(levelEl);
          strip.appendChild(fader.well);
          strip.appendChild(nameEl);

          consoleMasterEntry = {
            levelEl,
            vuMaskL: fader.vuMaskL,
            vuMaskR: fader.vuMaskR,
            setValue: fader.setValue
          };
          return strip;
        }

        function buildConsoleTrackStrip(t) {
          const strip = document.createElement("div");
          strip.className = "console-strip";

          const btns = document.createElement("div");
          btns.className = "strip-btns";
          const muteBtn = document.createElement("button");
          muteBtn.className = "mini-btn" + (t.isMuted ? " muted" : "");
          muteBtn.textContent = "M";
          muteBtn.addEventListener("click", () => sendCmd({ type: "toggleMute", trackId: t.id }));
          const soloBtn = document.createElement("button");
          soloBtn.className = "mini-btn" + (t.isSoloed ? " soloed" : "");
          soloBtn.textContent = "S";
          soloBtn.addEventListener("click", () => sendCmd({ type: "toggleSolo", trackId: t.id }));
          btns.appendChild(muteBtn);
          btns.appendChild(soloBtn);

          const panWrap = document.createElement("div");
          panWrap.className = "strip-pan-wrap";
          const panVal = document.createElement("div");
          panVal.className = "strip-submeta";
          panVal.textContent = fmtPan(t.pan);
          const panKey = "trkPan:" + t.id;
          const panFader = createHorizontalFader({
            sliderKey: panKey,
            min: -1, max: 1,
            bipolar: true,
            compactPan: true,
            initialValue: typeof t.pan === "number" ? t.pan : 0,
            resetValue: 0,
            extraClass: "pan-fader pan-compact",
            onUiUpdate: (p) => { panVal.textContent = fmtPan(p); },
            onInput: (p) => sendCmd({ type: "setTrackPan", trackId: t.id, pan: p }),
            onCommit: (p) => {
              sendCmd({ type: "setTrackPan", trackId: t.id, pan: p });
              sendCmd({ type: "commitTrackMix" });
            },
            onReset: () => resetTrackPan(t.id, null, panVal),
            onCancel: () => sendCmd({ type: "commitTrackMix" })
          });
          panWrap.appendChild(panFader.well);
          panWrap.appendChild(panVal);

          const capRole = stripCapClassForTrack(t);
          const volKey = "trkVol:" + t.id;
          const fader = createVerticalFaderWell({
            sliderKey: volKey,
            initialValue: t.volume,
            resetValue: defaultFaderLevel,
            capClass: capRole + (t.isMuted ? " muted" : ""),
            onInput: (v) => sendCmd({ type: "setTrackVolume", trackId: t.id, volume: v }),
            onCommit: (v) => {
              sendCmd({ type: "setTrackVolume", trackId: t.id, volume: v });
              sendCmd({ type: "commitTrackMix" });
            },
            onReset: () => resetTrackFader(t.id, null),
            onCancel: () => sendCmd({ type: "commitTrackMix" })
          });

          const nameEl = document.createElement("div");
          nameEl.className = "strip-name";
          nameEl.textContent = t.shortName || t.name || "";
          nameEl.title = t.name || "";

          strip.appendChild(btns);
          strip.appendChild(panWrap);
          strip.appendChild(fader.well);
          strip.appendChild(nameEl);

          trackDomById.set(t.id, {
            nameEl, panVal, muteBtn, soloBtn,
            capEl: fader.cap, capRole,
            vuMaskL: fader.vuMaskL, vuMaskR: fader.vuMaskR,
            setVolume: fader.setValue,
            setPan: panFader.setValue
          });
          return strip;
        }

        function buildConsoleBusStrip(b) {
          const strip = document.createElement("div");
          strip.className = "console-strip";

          const btns = document.createElement("div");
          btns.className = "strip-btns";
          const muteBtn = document.createElement("button");
          muteBtn.className = "mini-btn" + (b.isMuted ? " muted" : "");
          muteBtn.textContent = "M";
          muteBtn.addEventListener("click", () => sendCmd({ type: "toggleBusMute", busId: b.id }));
          const soloBtn = document.createElement("button");
          soloBtn.className = "mini-btn" + (b.isSoloed ? " soloed" : (b.isSoloSafe ? " solo-safe" : ""));
          soloBtn.textContent = "S";
          soloBtn.addEventListener("click", () => sendCmd({ type: "toggleBusSolo", busId: b.id }));
          btns.appendChild(muteBtn);
          btns.appendChild(soloBtn);

          const outEl = document.createElement("div");
          outEl.className = "strip-bus-pill";
          outEl.textContent = b.physicalOutputChannel || "";

          const capRole = stripCapClassForBus(b);
          const busKey = "busVol:" + b.id;
          const fader = createVerticalFaderWell({
            sliderKey: busKey,
            initialValue: b.volume,
            resetValue: 0.80,
            capClass: capRole + (b.isMuted ? " muted" : ""),
            onInput: (v) => sendCmd({ type: "setBusVolume", busId: b.id, volume: v }),
            onCommit: (v) => {
              sendCmd({ type: "setBusVolume", busId: b.id, volume: v });
              sendCmd({ type: "commitBusMix", busId: b.id });
            },
            onReset: () => resetBusFader(b.id, null),
            onCancel: () => sendCmd({ type: "commitBusMix", busId: b.id })
          });

          const nameEl = document.createElement("div");
          nameEl.className = "strip-name";
          nameEl.textContent = b.shortName || b.name || "";
          nameEl.title = b.name || "";

          strip.appendChild(btns);
          strip.appendChild(outEl);
          strip.appendChild(fader.well);
          strip.appendChild(nameEl);

          busDomById.set(b.id, {
            nameEl, outEl, muteBtn, soloBtn,
            capEl: fader.cap, capRole,
            vuMaskL: fader.vuMaskL, vuMaskR: fader.vuMaskR,
            setVolume: fader.setValue
          });
          return strip;
        }

        function renderMixer(s) {
          const tracks = s.tracks || [];
          const buses = s.buses || [];
          const isHoriz = (mixerLayout === "horizontal");
          const isBuses = (mixerTab === "buses");
          const items = isBuses ? buses : tracks;
          const idsKey = items.map(x => x.id).join("|");
          const mixerKey = mixerLayout + "|" + mixerTab + "|" + idsKey;
          const bodyEl = document.getElementById("mixerBody");

          if (mixerKey !== renderedMixerKey) {
            renderedMixerKey = mixerKey;
            trackDomById.clear();
            busDomById.clear();
            consoleMasterEntry = null;

            if (isHoriz) {
              const rack = document.createElement("div");
              rack.className = "console-rack";
              const masterStrip = buildConsoleMasterStrip(s);
              const divider = document.createElement("div");
              divider.className = "console-divider";
              const scroll = document.createElement("div");
              scroll.className = "console-scroll";
              const strips = isBuses
                ? buses.map(b => buildConsoleBusStrip(b))
                : tracks.map(t => buildConsoleTrackStrip(t));
              scroll.replaceChildren(...strips);
              rack.appendChild(masterStrip);
              rack.appendChild(divider);
              rack.appendChild(scroll);
              bodyEl.replaceChildren(rack);
            } else {
              const list = document.createElement("div");
              list.id = "tracks";
              const rows = isBuses
                ? buses.map(b => buildSideBusRow(b))
                : tracks.map(t => buildSideTrackRow(t));
              list.replaceChildren(...rows);
              bodyEl.replaceChildren(list);
            }
            if (lastMeters) applyMeters(lastMeters);
            return;
          }

          if (consoleMasterEntry && activeSlider !== "__master__") {
            consoleMasterEntry.setValue(s.masterVolume);
          }

          if (isBuses) {
            for (const b of buses) {
              const entry = busDomById.get(b.id);
              if (!entry) continue;
              entry.nameEl.textContent = b.shortName || b.name || "";
              entry.nameEl.title = b.name || "";
              entry.outEl.textContent = b.physicalOutputChannel || "";
              if (activeSlider !== ("busVol:" + b.id)) entry.setVolume(b.volume);
              entry.muteBtn.className = "mini-btn" + (b.isMuted ? " muted" : "");
              entry.soloBtn.className = "mini-btn" + (b.isSoloed ? " soloed" : (b.isSoloSafe ? " solo-safe" : ""));
              if (entry.capEl) {
                entry.capEl.className = "vfader-cap" + (entry.capRole ? " " + entry.capRole : "") + (b.isMuted ? " muted" : "");
              }
            }
          } else {
            for (const t of tracks) {
              const entry = trackDomById.get(t.id);
              if (!entry) continue;
              entry.nameEl.textContent = t.shortName || t.name || "";
              entry.nameEl.title = t.name || "";
              if (activeSlider !== ("trkVol:" + t.id)) entry.setVolume(t.volume);
              if (activeSlider !== ("trkPan:" + t.id) && entry.setPan) {
                entry.setPan(typeof t.pan === "number" ? t.pan : 0);
              }
              entry.muteBtn.className = "mini-btn" + (t.isMuted ? " muted" : "");
              entry.soloBtn.className = "mini-btn" + (t.isSoloed ? " soloed" : "");
              if (entry.capEl) {
                entry.capEl.className = "vfader-cap" + (entry.capRole ? " " + entry.capRole : "") + (t.isMuted ? " muted" : "");
              }
            }
          }
        }

        function render(s) {
          if (typeof s.defaultFaderLevel === "number") defaultFaderLevel = s.defaultFaderLevel;
          document.getElementById("songTitle").textContent = s.songTitle || "Untitled";
          document.getElementById("songArtist").textContent = s.artist || "";
          document.getElementById("songMeta").textContent =
            `${Math.round(s.bpm)} BPM • Key ${s.musicalKey} • ${fmt(s.currentTime)} / ${fmt(s.duration)}`;
          const playBtn = document.getElementById("playBtn");
          playBtn.textContent = s.isPlaying ? "PAUSE" : "PLAY";
          playBtn.className = s.isPlaying ? "play playing" : "play";
          const rtzBtn = document.getElementById("rtzBtn");
          if (s.isPostSongClickActive && !s.isPlaying) {
            rtzBtn.textContent = "STOP";
            rtzBtn.className = "stop-click";
          } else {
            rtzBtn.textContent = "RTZ";
            rtzBtn.className = "";
          }
          const loop1xBtn = document.getElementById("loop1xBtn");
          loop1xBtn.className = "span2" + (s.isLoopActive && s.loopMode === "single" ? " loop-active" : "");
          const loopInfBtn = document.getElementById("loopInfBtn");
          loopInfBtn.className = "span2" + (s.isLoopActive && s.loopMode === "infinite" ? " loop-active" : "");
          if (masterHFader && activeSlider !== "__master__") {
            masterHFader.setValue(s.masterVolume);
          }

          // Timeline ticks, hint, and playhead draw
          const sections = s.sections || [];
          const activeSec = sections.find(sec => sec.isActive);
          document.getElementById("activeSecLabel").textContent = activeSec ? activeSec.name : "";
          document.getElementById("progSecName").textContent = activeSec ? activeSec.name : "";
          document.getElementById("waveHint").textContent = s.isPlaying ? "Tap section to queue" : "Tap to seek";

          const ticksEl = document.getElementById("progressTicks");
          const dur = Math.max(0.01, s.duration || 0.01);
          const tickNodes = [];
          for (let i = 1; i < sections.length; i++) {
            const tk = document.createElement("div");
            tk.className = "prog-tick";
            tk.style.left = Math.max(0, Math.min(100, (sections[i].startTime / dur) * 100)).toFixed(2) + "%";
            tickNodes.push(tk);
          }
          ticksEl.replaceChildren(...tickNodes);

          if (timelineMode === "waveform") {
            drawWaveform(s.currentTime || 0);
          } else if (timelineMode === "progress") {
            updateProgressUI(s.currentTime || 0);
          }
          if (s.isPlaying && timelineMode !== "none") {
            startPlayheadLoop();
          } else {
            stopPlayheadLoop();
          }

          const secEl = document.getElementById("sections");
          const secButtons = sections.map((sec, idx) => {
            const btn = document.createElement("button");
            btn.className = "sec-btn" + (sec.isActive ? " active" : "") + (sec.isQueued ? " queued" : "");
            if (!sec.isActive && !sec.isQueued && sec.colorHex) {
              btn.style.borderLeftColor = sec.colorHex;
            }
            btn.textContent = sec.name || "";
            btn.addEventListener("click", () => sendCmd({ type: "jumpSection", sectionIndex: idx }));
            return btn;
          });
          secEl.replaceChildren(...secButtons);

          if (s.pad) {
            const p = s.pad;
            const fireBtn = document.getElementById("padFireBtn");
            fireBtn.className = "pad-fire " + (p.isActive ? "active" : "");
            const linkBtn = document.getElementById("padLinkBtn");
            linkBtn.className = "pad-link " + (p.isLinked ? "linked" : "");

            const packEl = document.getElementById("padPackSelect");
            const packs = p.packs || [];
            const packIdsKey = packs.map(pk => pk.id).join("|");
            if (packIdsKey !== lastPackIdsKey) {
              lastPackIdsKey = packIdsKey;
              const packOptions = packs.map(pk => {
                const opt = document.createElement("option");
                opt.value = pk.id || "";
                opt.textContent = pk.name || "";
                return opt;
              });
              packEl.replaceChildren(...packOptions);
            }
            if (document.activeElement !== packEl) {
              packEl.value = p.activePackId;
            }

            const activeKey = normKey(p.currentKey);
            const lockedKey = p.lockedKey ? normKey(p.lockedKey) : null;
            const padKeysEl = document.getElementById("padKeys");
            const keyButtons = PAD_KEYS.map(k => {
              const isSel = (k === activeKey);
              const isLockedOut = (lockedKey !== null && k !== lockedKey);
              const isLockedTarget = (lockedKey !== null && k === lockedKey);
              let cls = "key-btn";
              if (isSel) cls += (p.isActive ? " active" : " selected");
              if (isLockedTarget) cls += " locked-target";
              if (isLockedOut) cls += " locked";
              const btn = document.createElement("button");
              btn.className = cls;
              btn.textContent = k;
              btn.disabled = isLockedOut;
              if (isLockedOut) {
                btn.title = "Locked to song key (" + lockedKey + ") while playing with LINK enabled";
              }
              btn.addEventListener("click", () => {
                if (isLockedOut) return;
                sendCmd({ type: "setPadKey", padKey: k });
              });
              return btn;
            });
            padKeysEl.replaceChildren(...keyButtons);

            if (padVolHFader && activeSlider !== "__pad__") {
              padVolHFader.setValue(p.volume);
            }
            if (padPanHFader && activeSlider !== "__padPan__") {
              const panVal = typeof p.pan === "number" ? p.pan : 0;
              padPanHFader.setValue(panVal);
            }
            document.getElementById("padMuteBtn").className = "mini-btn " + (p.isMuted ? "muted" : "");
            document.getElementById("padSoloBtn").className = "mini-btn " + (p.isSoloed ? "soloed" : "");
          }

          const setEl = document.getElementById("setlist");
          const setRows = (s.setlist || []).map((item) => {
            const row = document.createElement("div");
            row.className = "setlist-item" + (item.isActive ? " active" : "");

            const leftCol = document.createElement("div");
            const titleEl = document.createElement("strong");
            titleEl.textContent = item.title || "";
            const artistEl = document.createElement("div");
            artistEl.className = "setlist-artist";
            artistEl.textContent = item.artist || "";
            leftCol.appendChild(titleEl);
            leftCol.appendChild(artistEl);

            const metaEl = document.createElement("div");
            metaEl.className = "setlist-meta";
            metaEl.textContent = `${Math.round(item.bpm)} BPM • ${item.musicalKey || ""}`;

            row.appendChild(leftCol);
            row.appendChild(metaEl);
            row.addEventListener("click", () => sendCmd({ type: "selectSong", songIndex: item.index }));
            return row;
          });
          setEl.replaceChildren(...setRows);

          renderMixer(s);
        }
        bindStaticControls();
        connect();
      </script>
    </body>
    </html>
    """
    }
}
