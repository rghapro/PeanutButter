import Foundation
import Network
import CryptoKit
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
    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var port: UInt16 = 8085
    @Published public private(set) var connectedClientCount: Int = 0
    @Published public private(set) var localURLString: String = ""
    @Published public private(set) var lastError: String? = nil

    @Published public var isPasswordRequired: Bool {
        didSet {
            UserDefaults.standard.set(isPasswordRequired, forKey: "Playback_RemotePasswordRequired")
        }
    }
    @Published public var remotePassword: String {
        didSet {
            UserDefaults.standard.set(remotePassword, forKey: "Playback_RemotePassword")
        }
    }

    private weak var engine: MultitrackAudioEngine?
    private var listener: NWListener?
    private var webSocketClients: [ObjectIdentifier: WebSocketClient] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var broadcastTimer: Timer?

    private let serverQueue = DispatchQueue(label: "com.peanutbutter.remote.server", qos: .userInitiated)

    public init(engine: MultitrackAudioEngine? = nil) {
        self.engine = engine
        self.isPasswordRequired = UserDefaults.standard.bool(forKey: "Playback_RemotePasswordRequired")
        self.remotePassword = UserDefaults.standard.string(forKey: "Playback_RemotePassword") ?? ""
    }

    private var requiresAuthCheck: Bool {
        isPasswordRequired && !remotePassword.isEmpty
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

    private func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: serverQueue)
        receiveHTTPRequest(on: connection, accumulated: Data())
    }

    private nonisolated func receiveHTTPRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let data = data {
                buffer.append(data)
            }
            if let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
                let headerString = String(data: headerData, encoding: .utf8) ?? ""
                Task { @MainActor [weak self] in
                    self?.routeHTTPRequest(headerString, on: connection)
                }
                return
            }
            if isComplete || buffer.count > 32768 {
                connection.cancel()
                return
            }
            self.receiveHTTPRequest(on: connection, accumulated: buffer)
        }
    }

    private func routeHTTPRequest(_ headerString: String, on connection: NWConnection) {
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            connection.cancel()
            return
        }
        let parts = requestLine.split(separator: " ")
        let path = parts.count >= 2 ? String(parts[1]) : "/"

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = val
            }
        }

        if headers["upgrade"]?.lowercased() == "websocket",
           let secKey = headers["sec-websocket-key"] {
            upgradeToWebSocket(secKey: secKey, on: connection)
            return
        }

        if path == "/api/state" {
            if requiresAuthCheck {
                let supplied = headers["x-remote-password"] ?? ""
                if supplied != remotePassword {
                    sendHTTPResponse(status: "401 Unauthorized", contentType: "application/json", body: Data("{\"error\":\"Unauthorized\"}".utf8), on: connection)
                    return
                }
            }
            if let snapshot = buildStateSnapshot(),
               let json = try? JSONEncoder().encode(snapshot) {
                sendHTTPResponse(status: "200 OK", contentType: "application/json; charset=utf-8", body: json, on: connection)
            } else {
                sendHTTPResponse(status: "503 Service Unavailable", contentType: "text/plain", body: Data("Engine unavailable".utf8), on: connection)
            }
            return
        }

        let htmlData = Data(Self.remoteWebClientHTML.utf8)
        sendHTTPResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: htmlData, on: connection)
    }

    private func sendHTTPResponse(status: String, contentType: String, body: Data, on connection: NWConnection) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
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
        let client = WebSocketClient(connection: connection, queue: serverQueue, isAuthenticated: !requiresAuthCheck)
        let clientId = ObjectIdentifier(client)
        webSocketClients[clientId] = client
        connectedClientCount = webSocketClients.count
        if broadcastTimer == nil {
            startBroadcastTimer()
        }

        client.onMessage = { [weak self, weak client] text in
            Task { @MainActor [weak self, weak client] in
                guard let self = self, let client = client else { return }
                self.handleIncomingMessage(text, from: client)
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

        let padPacks = PadLibraryManager.shared.availablePacks.map {
            RemotePadPackInfo(id: $0.id, name: $0.name)
        }
        let activePackId = (engine.padPlayer.isPlaying ? engine.padPlayer.activePackId : nil)
            ?? engine.manualPadPackId
            ?? engine.currentSong.padPresetId
            ?? engine.padPlayer.activePackId
            ?? PadLibraryManager.shared.activePackId

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

    public func handleIncomingMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let cmd = try? JSONDecoder().decode(RemoteCommand.self, from: data) else { return }
        applyCommand(cmd)
    }

    private func handleIncomingMessage(_ text: String, from client: WebSocketClient) {
        guard let data = text.data(using: .utf8),
              let cmd = try? JSONDecoder().decode(RemoteCommand.self, from: data) else { return }

        if cmd.type == "auth" {
            if !requiresAuthCheck || cmd.password == remotePassword {
                client.isAuthenticated = true
                if let snapshot = buildStateSnapshot(),
                   let json = try? JSONEncoder().encode(snapshot),
                   let snapText = String(data: json, encoding: .utf8) {
                    client.sendText(snapText)
                }
            } else {
                client.sendText("{\"type\":\"authFailed\"}")
            }
            return
        }

        guard client.isAuthenticated else {
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
        case "tapTempo":
            engine.tapTempo()
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
                engine.masterVolume = max(0.0, min(1.0, vol))
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
                let packId = engine.manualPadPackId ?? engine.currentSong.padPresetId ?? PadLibraryManager.shared.activePackId
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
                    let packId = engine.manualPadPackId ?? engine.currentSong.padPresetId ?? PadLibraryManager.shared.activePackId
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

private final class WebSocketClient {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var isClosed = false
    var isAuthenticated: Bool

    var onMessage: ((String) -> Void)?
    var onClose: (() -> Void)?

    init(connection: NWConnection, queue: DispatchQueue, isAuthenticated: Bool) {
        self.connection = connection
        self.queue = queue
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
    static let remoteWebClientHTML: String = """
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
        button.playing { background: var(--amber); color: #161005; }
        button.fade { background: rgba(240,72,84,0.2); color: #ff7a84; border: 1px solid rgba(240,72,84,0.35); }
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
        <input id="pwInput" type="password" placeholder="Enter remote password..." onkeydown="if(event.key==='Enter') submitAuth()" />
        <button class="play" style="width:100%;" onclick="submitAuth()">Unlock Remote</button>
        <div id="authErr" style="color:#ff7a84;font-size:12px;margin-top:8px;"></div>
      </div>

      <div id="mainUI" class="desktop-grid">
        <div class="col-center">
          <div class="card">
            <h1 id="songTitle" class="song-title">No Song Loaded</h1>
            <div id="songMeta" class="song-meta">-- BPM • Key -- • 0:00 / 0:00</div>
            <div class="transport">
              <button id="playBtn" class="play" onclick="sendCmd({type:'playPause'})">PLAY</button>
              <button onclick="sendCmd({type:'rtz'})">RTZ</button>
              <button class="fade" onclick="sendCmd({type:'fade'})">FADE</button>
              <button onclick="sendCmd({type:'prevSong'})">Prev Song</button>
              <button onclick="sendCmd({type:'nextSong'})">Next Song</button>
              <button onclick="sendCmd({type:'tapTempo'})" style="grid-column: span 2;">TAP TEMPO</button>
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
                <button id="padLinkBtn" class="pad-link" onclick="sendCmd({type:'togglePadLink'})">LINK</button>
                <button id="padFireBtn" class="pad-fire" onclick="sendCmd({type:'togglePad'})">PAD</button>
              </div>
            </div>
            <select id="padPackSelect" class="pad-select" onchange="sendCmd({type:'setPadPack', padPackId:this.value})"></select>
            <div id="padKeys" class="keys-grid"></div>
            <div class="track-row" style="border-bottom:none;padding-bottom:0;">
              <div class="track-name">PAD VOL</div>
              <input id="padVol" type="range" min="0" max="1" step="0.01"
                onpointerdown="faderDown('__pad__', event)"
                onpointerup="faderUp('__pad__', event, () => resetPadFader())"
                onpointercancel="activeSlider=null"
                ondblclick="resetPadFader()"
                oninput="throttledSlider('__pad__', () => sendCmd({type:'setPadVolume', volume:parseFloat(this.value)}))"
                onchange="activeSlider=null; sendCmd({type:'setPadVolume', volume:parseFloat(this.value)})" />
              <button id="padMuteBtn" class="mini-btn" onclick="sendCmd({type:'togglePadMute'})">M</button>
              <button id="padSoloBtn" class="mini-btn" onclick="sendCmd({type:'togglePadSolo'})">S</button>
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
              <input id="masterVol" type="range" min="0" max="1" step="0.01"
                onpointerdown="faderDown('__master__', event)"
                onpointerup="faderUp('__master__', event, () => resetMasterFader())"
                onpointercancel="activeSlider=null"
                ondblclick="resetMasterFader()"
                oninput="throttledSlider('__master__', () => sendCmd({type:'setMasterVolume', volume:parseFloat(this.value)}))"
                onchange="activeSlider=null; sendCmd({type:'setMasterVolume', volume:parseFloat(this.value)})" />
              <div></div><div></div>
            </div>
            <div id="tracks"></div>
          </div>
        </div>
      </div>

      <script>
        let ws;
        let activeSlider = null;
        let lastSliderAt = 0;
        let lastTrackIdsKey = "";
        let lastPackIdsKey = "";
        let defaultFaderLevel = 0.80;
        let tapState = {};
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
        function resetTrackFader(id) {
          const el = document.getElementById("sl_" + id);
          if (el) el.value = defaultFaderLevel;
          sendCmd({ type: "setTrackVolume", trackId: id, volume: defaultFaderLevel });
          sendCmd({ type: "commitTrackMix" });
        }
        function submitAuth() {
          const pw = document.getElementById("pwInput").value || "";
          sendCmd({ type: "auth", password: pw });
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
              document.getElementById("authErr").textContent = "Incorrect password.";
              return;
            }
            document.getElementById("authCard").style.display = "none";
            document.getElementById("mainUI").style.display = "";
            render(msg);
          };
        }
        function sendCmd(obj) {
          if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj));
        }
        function normKey(k) {
          const map = { "C#":"Db", "D#":"Eb", "F#":"Gb", "G#":"Ab", "A#":"Bb" };
          return map[k] || k;
        }
        function render(s) {
          if (typeof s.defaultFaderLevel === "number") defaultFaderLevel = s.defaultFaderLevel;
          document.getElementById("songTitle").textContent = s.songTitle || "Untitled";
          document.getElementById("songMeta").textContent =
            `${Math.round(s.bpm)} BPM • Key ${s.musicalKey} • ${fmt(s.currentTime)} / ${fmt(s.duration)}`;
          const playBtn = document.getElementById("playBtn");
          playBtn.textContent = s.isPlaying ? "PAUSE" : "PLAY";
          playBtn.className = s.isPlaying ? "play playing" : "play";
          if (activeSlider !== "__master__") {
            document.getElementById("masterVol").value = s.masterVolume;
          }

          const secEl = document.getElementById("sections");
          secEl.innerHTML = (s.sections || []).map((sec, idx) =>
            `<button class="sec-btn ${sec.isActive ? 'active' : ''} ${sec.isQueued ? 'queued' : ''}" onclick="sendCmd({type:'jumpSection', sectionIndex:${idx}})">${sec.name}</button>`
          ).join("");

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
              packEl.innerHTML = packs.map(pk => `<option value="${pk.id}">${pk.name}</option>`).join("");
            }
            if (document.activeElement !== packEl) {
              packEl.value = p.activePackId;
            }

            const activeKey = normKey(p.currentKey);
            document.getElementById("padKeys").innerHTML = PAD_KEYS.map(k => {
              const isSel = (k === activeKey);
              const cls = isSel ? (p.isActive ? "active" : "selected") : "";
              return `<button class="key-btn ${cls}" onclick="sendCmd({type:'setPadKey', padKey:'${k}'})">${k}</button>`;
            }).join("");

            if (activeSlider !== "__pad__") {
              document.getElementById("padVol").value = p.volume;
            }
            document.getElementById("padMuteBtn").className = "mini-btn " + (p.isMuted ? "muted" : "");
            document.getElementById("padSoloBtn").className = "mini-btn " + (p.isSoloed ? "soloed" : "");
          }

          const setEl = document.getElementById("setlist");
          setEl.innerHTML = (s.setlist || []).map((item) =>
            `<div class="setlist-item ${item.isActive ? 'active' : ''}" onclick="sendCmd({type:'selectSong', songIndex:${item.index}})">
              <div><strong>${item.title}</strong><div style="font-size:11px;color:#8b93a6;">${item.artist}</div></div>
              <div style="font-size:12px;color:#8b93a6;">${Math.round(item.bpm)} BPM • ${item.musicalKey}</div>
            </div>`
          ).join("");

          const tracks = s.tracks || [];
          const trackIdsKey = tracks.map(t => t.id).join("|");
          const trEl = document.getElementById("tracks");

          if (trackIdsKey !== lastTrackIdsKey) {
            lastTrackIdsKey = trackIdsKey;
            trEl.innerHTML = tracks.map((t) =>
              `<div class="track-row" data-tid="${t.id}">
                <div class="track-name">${t.name}</div>
                <input id="sl_${t.id}" type="range" min="0" max="1" step="0.01" value="${t.volume}"
                  onpointerdown="faderDown('${t.id}', event)"
                  onpointerup="faderUp('${t.id}', event, () => resetTrackFader('${t.id}'), () => sendCmd({type:'commitTrackMix'}))"
                  onpointercancel="activeSlider=null; sendCmd({type:'commitTrackMix'})"
                  ondblclick="resetTrackFader('${t.id}')"
                  oninput="throttledSlider('${t.id}', () => sendCmd({type:'setTrackVolume', trackId:'${t.id}', volume:parseFloat(this.value)}))"
                  onchange="activeSlider=null; sendCmd({type:'setTrackVolume', trackId:'${t.id}', volume:parseFloat(this.value)}); sendCmd({type:'commitTrackMix'})" />
                <button id="m_${t.id}" class="mini-btn ${t.isMuted ? 'muted' : ''}" onclick="sendCmd({type:'toggleMute', trackId:'${t.id}'})">M</button>
                <button id="s_${t.id}" class="mini-btn ${t.isSoloed ? 'soloed' : ''}" onclick="sendCmd({type:'toggleSolo', trackId:'${t.id}'})">S</button>
              </div>`
            ).join("");
          } else {
            for (const t of tracks) {
              const sl = document.getElementById("sl_" + t.id);
              if (sl && activeSlider !== t.id) sl.value = t.volume;
              const mb = document.getElementById("m_" + t.id);
              if (mb) mb.className = "mini-btn " + (t.isMuted ? "muted" : "");
              const sb = document.getElementById("s_" + t.id);
              if (sb) sb.className = "mini-btn " + (t.isSoloed ? "soloed" : "");
            }
          }
        }
        connect();
      </script>
    </body>
    </html>
    """
}
