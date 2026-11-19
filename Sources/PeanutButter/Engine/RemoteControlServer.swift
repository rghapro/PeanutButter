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
    public let role: String
    public let volume: Float
    public let isMuted: Bool
    public let isSoloed: Bool
    public let assignedBusName: String
}

public struct RemotePadPackInfo: Codable, Sendable {
    public let id: String
    public let name: String
}

public struct RemotePadState: Codable, Sendable {
    public let isActive: Bool
    public let isLinked: Bool
    public let currentKey: String
    public let activePackId: String
    public let volume: Float
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
    public let pad: RemotePadState
    public let sections: [RemoteSectionInfo]
    public let setlist: [RemoteSongInfo]
    public let tracks: [RemoteTrackInfo]
}

public struct RemoteCommand: Codable, Sendable {
    public let type: String
    public let sectionIndex: Int?
    public let songIndex: Int?
    public let trackId: String?
    public let volume: Float?
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
        guard !webSocketClients.isEmpty else {
            broadcastTimer = nil
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
                    if let snapshot = self.buildStateSnapshot(),
                       let json = try? JSONEncoder().encode(snapshot),
                       let text = String(data: json, encoding: .utf8) {
                        client.sendText(text)
                    }
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
                isQueued: queuedId == sec.id
            )
        }

        let setlist = engine.currentSetlist.songs.enumerated().map { idx, item in
            RemoteSongInfo(
                index: idx,
                id: item.id.uuidString,
                title: item.title,
                artist: item.artist,
                bpm: item.bpm,
                musicalKey: item.musicalKey,
                isActive: idx == engine.currentSongIndex
            )
        }

        let tracks = engine.tracks.map { track in
            RemoteTrackInfo(
                id: track.id.uuidString,
                name: track.name,
                role: track.role.rawValue,
                volume: track.volume,
                isMuted: track.isMuted,
                isSoloed: track.isSoloed,
                assignedBusName: track.assignedBusName
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
            activePackId: activePackId,
            volume: engine.padChannelVolume,
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
            bpm: song.bpm,
            musicalKey: song.musicalKey,
            isPlaying: engine.playbackState == .playing,
            currentTime: currentTime,
            duration: engine.currentSongDuration,
            masterVolume: engine.masterVolume,
            defaultFaderLevel: engine.defaultChannelFaderLevel,
            currentSongIndex: engine.currentSongIndex,
            isLoopActive: engine.isLoopActive,
            loopMode: loopModeStr,
            isPostSongClickActive: engine.isPostSongClickActive,
            pad: padState,
            sections: sections,
            setlist: setlist,
            tracks: tracks
        )
    }

    public func broadcastStateIfNeeded() {
        guard isRunning, !webSocketClients.isEmpty,
              let snapshot = buildStateSnapshot(),
              let data = try? JSONEncoder().encode(snapshot),
              let text = String(data: data, encoding: .utf8) else { return }

        for client in webSocketClients.values where client.isAuthenticated {
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
                if let snapshot = buildStateSnapshot(),
                   let json = try? JSONEncoder().encode(snapshot),
                   let snapText = String(data: json, encoding: .utf8) {
                    client.sendText(snapText)
                }
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
                if let snapshot = buildStateSnapshot(),
                   let json = try? JSONEncoder().encode(snapshot),
                   let snapText = String(data: json, encoding: .utf8) {
                    client.sendText(snapText)
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

            recordAuthResult(success: ok, forIP: client.ipAddress)
            if ok {
                client.isAuthenticated = true
                client.unauthenticatedMessageCount = 0
                if let snapshot = buildStateSnapshot(),
                   let json = try? JSONEncoder().encode(snapshot),
                   let snapText = String(data: json, encoding: .utf8) {
                    client.sendText(snapText)
                }
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
          --bg: #0f1115;
          --card: #181b22;
          --border: #2a2f3a;
          --accent: #35c46b;
          --blue: #3aa0ff;
          --red: #f04854;
          --amber: #f5a623;
          --text: #f3f5f8;
          --muted: #8b93a6;
        }
        * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
        body {
          margin: 0; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
          background: var(--bg); color: var(--text); padding: 14px; padding-bottom: 40px;
        }
        .header {
          display: flex; justify-content: space-between; align-items: center;
          margin-bottom: 12px;
        }
        .brand { font-weight: 800; font-size: 15px; letter-spacing: 0.4px; }
        .badge {
          font-size: 11px; font-weight: 700; padding: 4px 8px; border-radius: 999px;
          background: #232834; color: var(--muted);
        }
        .badge.ok { background: rgba(53,196,107,0.16); color: var(--accent); }
        .card {
          background: var(--card); border: 1px solid var(--border);
          border-radius: 12px; padding: 14px; margin-bottom: 12px;
        }
        .song-title { font-size: 20px; font-weight: 800; margin: 0; }
        .song-meta { font-size: 13px; color: var(--muted); margin-top: 4px; }
        .transport {
          display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; margin-top: 12px;
        }
        button {
          border: none; border-radius: 10px; padding: 12px 8px; font-weight: 700;
          font-size: 14px; color: var(--text); background: #262b36; cursor: pointer;
        }
        button:active { transform: scale(0.97); }
        button.play { background: var(--accent); color: #09140d; grid-column: span 2; }
        button.span2 { grid-column: span 2; }
        button.playing { background: var(--amber); color: #161005; }
        button.fade { background: rgba(240,72,84,0.2); color: #ff7a84; border: 1px solid rgba(240,72,84,0.35); }
        button.loop-active { background: rgba(77,163,255,0.22); color: var(--blue); border: 1px solid var(--blue); }
        button.stop-click { background: rgba(64,191,242,0.18); color: #40bff2; border: 1px solid rgba(64,191,242,0.55); }
        .section-title { font-size: 11px; font-weight: 800; letter-spacing: 0.8px; color: var(--muted); margin: 0 0 8px 0; text-transform: uppercase; }
        .sections-grid { display: flex; flex-wrap: wrap; gap: 6px; }
        .sec-btn { padding: 8px 12px; font-size: 12px; background: #222732; border: 1px solid var(--border); }
        .sec-btn.active { background: var(--blue); color: #061320; border-color: var(--blue); }
        .sec-btn.queued { background: rgba(242,179,61,0.22); color: var(--amber); border-color: var(--amber); }
        .setlist-item {
          display: flex; justify-content: space-between; align-items: center;
          padding: 10px 12px; border-radius: 8px; background: #1e222b; margin-bottom: 6px;
          cursor: pointer; border: 1px solid transparent;
        }
        .setlist-item.active { border-color: var(--accent); background: rgba(53,196,107,0.1); }
        .track-row {
          display: grid; grid-template-columns: 110px 1fr 34px 34px; gap: 8px; align-items: center;
          padding: 7px 0; border-bottom: 1px solid #222631;
        }
        .track-row:last-child { border-bottom: none; }
        .track-name { font-size: 13px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        input[type=range] { width: 100%; accent-color: var(--blue); }
        input[type=password] {
          width: 100%; padding: 10px 12px; border-radius: 8px; border: 1px solid var(--border);
          background: #101218; color: var(--text); font-size: 14px; margin-bottom: 10px;
        }
        .mini-btn { padding: 6px 0; font-size: 11px; border-radius: 6px; }
        .mini-btn.muted { background: var(--red); color: white; }
        .mini-btn.soloed { background: var(--amber); color: #161005; }
        .pad-header { display: flex; justify-content: space-between; align-items: center; gap: 8px; margin-bottom: 10px; }
        .pad-actions { display: flex; gap: 6px; }
        .pad-fire {
          padding: 7px 14px; font-size: 11px; font-weight: 800; letter-spacing: 0.6px;
          background: #1d2028; color: #42ef7f; border: 1.5px solid #303644; border-radius: 7px;
        }
        .pad-fire.active {
          background: rgba(53,196,107,0.14); color: #42ef7f;
          border-color: #35c46b; box-shadow: 0 0 10px rgba(53,196,107,0.2);
        }
        .pad-link { padding: 7px 10px; font-size: 11px; font-weight: 800; background: #1d2028; color: #7a8396; border: 1px solid #303644; border-radius: 7px; }
        .pad-link.linked { background: rgba(53,196,107,0.14); color: #42ef7f; border-color: rgba(53,196,107,0.5); }
        select.pad-select {
          width: 100%; padding: 8px 10px; border-radius: 8px; border: 1px solid var(--border);
          background: #101218; color: var(--text); font-size: 13px; margin-bottom: 10px;
        }
        .keys-grid { display: grid; grid-template-columns: repeat(6, 1fr); gap: 6px; margin-bottom: 10px; }
        .key-btn { padding: 10px 4px; font-size: 13px; font-weight: 700; background: #20242d; border: 1px solid #303644; border-radius: 7px; color: var(--text); }
        .key-btn.selected { border-color: rgba(255,255,255,0.35); }
        .key-btn.active { background: rgba(53,196,107,0.2); color: #42ef7f; border-color: #35c46b; box-shadow: 0 0 8px rgba(53,196,107,0.18); }
        .setlist-artist { font-size: 11px; color: #8b93a6; }
        .setlist-meta { font-size: 12px; color: #8b93a6; }

        /* Compact 3-column Desktop Layout */
        @media (min-width: 900px) {
          body { padding: 14px 20px; max-width: 1340px; margin: 0 auto; }
          .header { margin-bottom: 10px; }
          #mainUI.desktop-grid {
            display: grid;
            grid-template-columns: 270px 1fr 340px;
            grid-template-areas:
              "setlist center mixer";
            gap: 12px;
            align-items: start;
          }
          .col-setlist { grid-area: setlist; max-height: calc(100vh - 70px); overflow-y: auto; }
          .col-center { grid-area: center; display: flex; flex-direction: column; gap: 12px; }
          .col-center .card, .col-setlist .card, .col-mixer .card { margin-bottom: 0; }
          .col-mixer { grid-area: mixer; max-height: calc(100vh - 70px); overflow-y: auto; }
          .card { padding: 12px; border-radius: 10px; }
          .song-title { font-size: 17px; }
          button { padding: 9px 8px; font-size: 12.5px; }
          .key-btn { padding: 8px 4px; font-size: 12.5px; }
          .track-row { grid-template-columns: 95px 1fr 28px 28px; padding: 5px 0; }
          .setlist-item { padding: 8px 10px; font-size: 12.5px; }
        }
      </style>
    </head>
    <body>
      <div class="header">
        <div class="brand">PEANUTBUTTER REMOTE</div>
        <div id="conn" class="badge">Connecting...</div>
      </div>

      <div id="authCard" class="card" style="display:none;">
        <div class="section-title">Password Required</div>
        <input id="pwInput" type="password" placeholder="Enter remote password..." />
        <button id="unlockBtn" class="play" style="width:100%;">Unlock Remote</button>
        <div id="authErr" style="color:#ff7a84;font-size:12px;margin-top:8px;"></div>
      </div>

      <div id="mainUI" class="desktop-grid">
        <div class="col-center">
          <div class="card">
            <h1 id="songTitle" class="song-title">No Song Loaded</h1>
            <div id="songMeta" class="song-meta">-- BPM • Key -- • 0:00 / 0:00</div>
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

          <div class="card">
            <div class="section-title">Sections</div>
            <div id="sections" class="sections-grid"></div>
          </div>

          <div class="card">
            <div class="pad-header">
              <div class="section-title" style="margin:0;">Pad Player</div>
              <div class="pad-actions">
                <button id="padLinkBtn" class="pad-link">LINK</button>
                <button id="padFireBtn" class="pad-fire">PAD</button>
              </div>
            </div>
            <select id="padPackSelect" class="pad-select"></select>
            <div id="padKeys" class="keys-grid"></div>
            <div class="track-row" style="border-bottom:none;padding-bottom:0;">
              <div class="track-name">PAD VOL</div>
              <input id="padVol" type="range" min="0" max="1" step="0.01" />
              <button id="padMuteBtn" class="mini-btn">M</button>
              <button id="padSoloBtn" class="mini-btn">S</button>
            </div>
          </div>
        </div>

        <div class="col-setlist">
          <div class="card">
            <div class="section-title">Setlist</div>
            <div id="setlist"></div>
          </div>
        </div>

        <div class="col-mixer">
          <div class="card">
            <div class="section-title">Mixer <span style="font-weight:500;text-transform:none;letter-spacing:0;opacity:0.7;">(double-tap for 0 dB)</span></div>
            <div class="track-row">
              <div class="track-name">MASTER</div>
              <input id="masterVol" type="range" min="0" max="1" step="0.01" />
              <div></div><div></div>
            </div>
            <div id="tracks"></div>
          </div>
        </div>
      </div>

      <script nonce="\(cspNonce)">
        let ws;
        let activeSlider = null;
        let lastSliderAt = 0;
        let lastTrackIdsKey = "";
        let lastPackIdsKey = "";
        let defaultFaderLevel = 0.80;
        let tapState = {};
        const trackDomById = new Map();
        const PAD_KEYS = ["Db", "Eb", "Gb", "Ab", "Bb", "B", "C", "D", "E", "F", "G", "A"];

        function fmt(t) {
          t = Math.max(0, Math.floor(t || 0));
          return Math.floor(t / 60) + ":" + String(t % 60).padStart(2, "0");
        }
        function throttledSlider(id, fn) {
          const now = Date.now();
          if (now - lastSliderAt >= 35) {
            lastSliderAt = now;
            fn();
          }
        }
        function faderDown(id, ev) {
          activeSlider = id;
          tapState[id] = { x: ev.clientX || 0, y: ev.clientY || 0, lastTap: (tapState[id] && tapState[id].lastTap) || 0 };
        }
        function faderUp(id, ev, onDoubleTap, onEnd) {
          activeSlider = null;
          const st = tapState[id] || { x: 0, y: 0, lastTap: 0 };
          const dist = Math.hypot((ev.clientX || 0) - st.x, (ev.clientY || 0) - st.y);
          const now = Date.now();
          if (dist < 6) {
            if (now - st.lastTap < 340) {
              st.lastTap = 0;
              tapState[id] = st;
              onDoubleTap();
              return;
            }
            st.lastTap = now;
            tapState[id] = st;
          }
          if (onEnd) onEnd();
        }
        function resetMasterFader() {
          const el = document.getElementById("masterVol");
          if (el) el.value = defaultFaderLevel;
          sendCmd({ type: "setMasterVolume", volume: defaultFaderLevel });
        }
        function resetPadFader() {
          const el = document.getElementById("padVol");
          if (el) el.value = defaultFaderLevel;
          sendCmd({ type: "setPadVolume", volume: defaultFaderLevel });
        }
        function resetTrackFader(id, sliderEl) {
          if (sliderEl) sliderEl.value = defaultFaderLevel;
          sendCmd({ type: "setTrackVolume", trackId: id, volume: defaultFaderLevel });
          sendCmd({ type: "commitTrackMix" });
        }
        function submitAuth() {
          const pw = document.getElementById("pwInput").value || "";
          sendCmd({ type: "auth", password: pw });
        }
        function sendCmd(obj) {
          if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj));
        }
        function normKey(k) {
          const map = { "C#":"Db", "D#":"Eb", "F#":"Gb", "G#":"Ab", "A#":"Bb" };
          return map[k] || k;
        }

        function bindStaticControls() {
          const pwInput = document.getElementById("pwInput");
          pwInput.addEventListener("keydown", (event) => {
            if (event.key === "Enter") submitAuth();
          });
          document.getElementById("unlockBtn").addEventListener("click", submitAuth);

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

          const padVol = document.getElementById("padVol");
          padVol.addEventListener("pointerdown", (ev) => faderDown("__pad__", ev));
          padVol.addEventListener("pointerup", (ev) => faderUp("__pad__", ev, () => resetPadFader()));
          padVol.addEventListener("pointercancel", () => { activeSlider = null; });
          padVol.addEventListener("dblclick", () => resetPadFader());
          padVol.addEventListener("input", () => throttledSlider("__pad__", () => sendCmd({ type: "setPadVolume", volume: parseFloat(padVol.value) })));
          padVol.addEventListener("change", () => {
            activeSlider = null;
            sendCmd({ type: "setPadVolume", volume: parseFloat(padVol.value) });
          });

          document.getElementById("padMuteBtn").addEventListener("click", () => sendCmd({ type: "togglePadMute" }));
          document.getElementById("padSoloBtn").addEventListener("click", () => sendCmd({ type: "togglePadSolo" }));

          const masterVol = document.getElementById("masterVol");
          masterVol.addEventListener("pointerdown", (ev) => faderDown("__master__", ev));
          masterVol.addEventListener("pointerup", (ev) => faderUp("__master__", ev, () => resetMasterFader()));
          masterVol.addEventListener("pointercancel", () => { activeSlider = null; });
          masterVol.addEventListener("dblclick", () => resetMasterFader());
          masterVol.addEventListener("input", () => throttledSlider("__master__", () => sendCmd({ type: "setMasterVolume", volume: parseFloat(masterVol.value) })));
          masterVol.addEventListener("change", () => {
            activeSlider = null;
            sendCmd({ type: "setMasterVolume", volume: parseFloat(masterVol.value) });
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
            document.getElementById("authCard").style.display = "none";
            document.getElementById("mainUI").style.display = "";
            render(msg);
          };
        }

        function render(s) {
          if (typeof s.defaultFaderLevel === "number") defaultFaderLevel = s.defaultFaderLevel;
          document.getElementById("songTitle").textContent = s.songTitle || "Untitled";
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
          if (activeSlider !== "__master__") {
            document.getElementById("masterVol").value = s.masterVolume;
          }

          const secEl = document.getElementById("sections");
          const secButtons = (s.sections || []).map((sec, idx) => {
            const btn = document.createElement("button");
            btn.className = "sec-btn" + (sec.isActive ? " active" : "") + (sec.isQueued ? " queued" : "");
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
            const padKeysEl = document.getElementById("padKeys");
            const keyButtons = PAD_KEYS.map(k => {
              const isSel = (k === activeKey);
              const cls = isSel ? (p.isActive ? "active" : "selected") : "";
              const btn = document.createElement("button");
              btn.className = "key-btn" + (cls ? " " + cls : "");
              btn.textContent = k;
              btn.addEventListener("click", () => sendCmd({ type: "setPadKey", padKey: k }));
              return btn;
            });
            padKeysEl.replaceChildren(...keyButtons);

            if (activeSlider !== "__pad__") {
              document.getElementById("padVol").value = p.volume;
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

          const tracks = s.tracks || [];
          const trackIdsKey = tracks.map(t => t.id).join("|");
          const trEl = document.getElementById("tracks");

          if (trackIdsKey !== lastTrackIdsKey) {
            lastTrackIdsKey = trackIdsKey;
            trackDomById.clear();
            const rowNodes = tracks.map((t) => {
              const row = document.createElement("div");
              row.className = "track-row";
              row.dataset.tid = t.id;

              const nameEl = document.createElement("div");
              nameEl.className = "track-name";
              nameEl.textContent = t.name || "";

              const slider = document.createElement("input");
              slider.type = "range";
              slider.min = "0";
              slider.max = "1";
              slider.step = "0.01";
              slider.value = t.volume;
              slider.addEventListener("pointerdown", (ev) => faderDown(t.id, ev));
              slider.addEventListener("pointerup", (ev) => faderUp(
                t.id,
                ev,
                () => resetTrackFader(t.id, slider),
                () => sendCmd({ type: "commitTrackMix" })
              ));
              slider.addEventListener("pointercancel", () => {
                activeSlider = null;
                sendCmd({ type: "commitTrackMix" });
              });
              slider.addEventListener("dblclick", () => resetTrackFader(t.id, slider));
              slider.addEventListener("input", () => {
                throttledSlider(t.id, () => sendCmd({ type: "setTrackVolume", trackId: t.id, volume: parseFloat(slider.value) }));
              });
              slider.addEventListener("change", () => {
                activeSlider = null;
                sendCmd({ type: "setTrackVolume", trackId: t.id, volume: parseFloat(slider.value) });
                sendCmd({ type: "commitTrackMix" });
              });

              const muteBtn = document.createElement("button");
              muteBtn.className = "mini-btn" + (t.isMuted ? " muted" : "");
              muteBtn.textContent = "M";
              muteBtn.addEventListener("click", () => sendCmd({ type: "toggleMute", trackId: t.id }));

              const soloBtn = document.createElement("button");
              soloBtn.className = "mini-btn" + (t.isSoloed ? " soloed" : "");
              soloBtn.textContent = "S";
              soloBtn.addEventListener("click", () => sendCmd({ type: "toggleSolo", trackId: t.id }));

              row.appendChild(nameEl);
              row.appendChild(slider);
              row.appendChild(muteBtn);
              row.appendChild(soloBtn);

              trackDomById.set(t.id, { row, nameEl, slider, muteBtn, soloBtn });
              return row;
            });
            trEl.replaceChildren(...rowNodes);
          } else {
            for (const t of tracks) {
              const entry = trackDomById.get(t.id);
              if (!entry) continue;
              entry.nameEl.textContent = t.name || "";
              if (activeSlider !== t.id) entry.slider.value = t.volume;
              entry.muteBtn.className = "mini-btn " + (t.isMuted ? "muted" : "");
              entry.soloBtn.className = "mini-btn " + (t.isSoloed ? "soloed" : "");
            }
          }
        }
        bindStaticControls();
        connect();
      </script>
    </body>
    </html>
    """
    }
}
