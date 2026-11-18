import Foundation
import CoreMIDI
import Combine
import Darwin

/// Represents an available MIDI Output destination on macOS (hardware MIDI port, IAC Driver, Network MIDI, or Virtual Source)
public struct MIDIOutputDestination: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let endpointRef: MIDIEndpointRef
    public let isVirtual: Bool
    
    public init(id: String, name: String, endpointRef: MIDIEndpointRef, isVirtual: Bool = false) {
        self.id = id
        self.name = name
        self.endpointRef = endpointRef
        self.isVirtual = isVirtual
    }
}

/// CoreMIDI Output Engine that discovers connected MIDI output devices, exposes Virtual MIDI Sources,
/// and transmits MIDI Cues & ProPresenter Playlist/Item triggers across the 8 MultiTracks Playback buses.
public final class MIDICueEngine: ObservableObject, @unchecked Sendable {
    public static let shared = MIDICueEngine()
    
    public static let allOutputsID = "all_outputs"
    public static let virtualOnlyID = "virtual_source_only"
    
    @Published public private(set) var availableDestinations: [MIDIOutputDestination] = []
    
    /// Global target MIDI output destination ID (`all_outputs`, `virtual_source_only`, or a specific CoreMIDI destination ID)
    @Published public var selectedDestinationID: String = MIDICueEngine.allOutputsID {
        didSet {
            UserDefaults.standard.set(selectedDestinationID, forKey: "PeanutButter_SelectedMIDIDestinationID")
        }
    }
    
    /// Optional per-bus MIDI output destination override (defaults to `nil` = use `selectedDestinationID`)
    @Published public var busDestinationOverrides: [MIDIBus: String] = [:]
    
    /// Per-bus mute/disable state: disabled buses hide their cues on the timeline and do not transmit MIDI
    @Published public var disabledBuses: Set<MIDIBus> = [] {
        didSet {
            UserDefaults.standard.set(disabledBuses.map(\.rawValue), forKey: "PeanutButter_DisabledMIDIBuses")
        }
    }
    
    public func isBusEnabled(_ bus: MIDIBus) -> Bool {
        !disabledBuses.contains(bus)
    }
    
    public func setBusEnabled(_ bus: MIDIBus, enabled: Bool) {
        if enabled {
            disabledBuses.remove(bus)
        } else {
            disabledBuses.insert(bus)
        }
    }
    
    /// Configurable 1-based MIDI channel (1..16) for each of the 8 MIDI buses
    @Published public var busChannels: [MIDIBus: Int] = {
        var map: [MIDIBus: Int] = [:]
        for bus in MIDIBus.allCases {
            map[bus] = Int(bus.defaultChannel)
        }
        return map
    }()
    
    /// Enables transmitting 24 PPQN MIDI Beat Clock (`0xF8`) + Start/Continue/Stop (`0xFA`/`0xFB`/`0xFC`)
    @Published public var isMIDIClockEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isMIDIClockEnabled, forKey: "PeanutButter_MIDIClockEnabled")
            if !isMIDIClockEnabled {
                stopMIDIClock()
            }
        }
    }
    
    /// Multi-select set of MIDI output destination IDs that receive MIDI Clock
    @Published public var midiClockDestinationIDs: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(midiClockDestinationIDs), forKey: "PeanutButter_MIDIClockDestinationIDs")
            let snapshot = midiClockDestinationIDs
            clockQueue.async { [weak self] in
                self?.clockTargetIDs = snapshot
            }
        }
    }
    
    private var midiClient: MIDIClientRef = 0
    private var outputPort: MIDIPortRef = 0
    private var masterVirtualSource: MIDIEndpointRef = 0
    private var busVirtualSources: [MIDIBus: MIDIEndpointRef] = [:]
    private let queue = DispatchQueue(label: "com.peanutbutter.midicueengine", qos: .userInteractive)
    
    // High-precision MIDI Clock scheduler state (mutated only on `clockQueue`)
    private let clockQueue = DispatchQueue(label: "com.peanutbutter.midiclock", qos: .userInteractive)
    private var clockTimer: DispatchSourceTimer?
    private var isClockRunning: Bool = false
    private var clockBPM: Double = 120.0
    private var nextPulseHostTime: UInt64 = 0
    private var clockTargetIDs: Set<String> = []
    private var clockEndpointsCache: [MIDIOutputDestination] = []
    private let timebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
    
    private init() {
        if let saved = UserDefaults.standard.string(forKey: "PeanutButter_SelectedMIDIDestinationID") {
            self.selectedDestinationID = saved
        }
        self.isMIDIClockEnabled = UserDefaults.standard.bool(forKey: "PeanutButter_MIDIClockEnabled")
        if let savedClockIDs = UserDefaults.standard.stringArray(forKey: "PeanutButter_MIDIClockDestinationIDs") {
            let set = Set(savedClockIDs)
            self.midiClockDestinationIDs = set
            self.clockTargetIDs = set
        }
        if let savedDisabled = UserDefaults.standard.stringArray(forKey: "PeanutButter_DisabledMIDIBuses") {
            self.disabledBuses = Set(savedDisabled.compactMap { MIDIBus(rawValue: $0) })
        }
        setupCoreMIDI()
        refreshDestinations()
    }
    
    deinit {
        clockTimer?.cancel()
        clockTimer = nil
        if masterVirtualSource != 0 {
            MIDIEndpointDispose(masterVirtualSource)
        }
        for (_, endpoint) in busVirtualSources {
            if endpoint != 0 {
                MIDIEndpointDispose(endpoint)
            }
        }
        if outputPort != 0 {
            MIDIPortDispose(outputPort)
        }
        if midiClient != 0 {
            MIDIClientDispose(midiClient)
        }
    }
    
    private func setupCoreMIDI() {
        let clientStatus = MIDIClientCreateWithBlock("PeanutButter MIDI Client" as CFString, &midiClient) { [weak self] notificationPtr in
            let msgID = notificationPtr.pointee.messageID
            if msgID == .msgSetupChanged || msgID == .msgObjectAdded || msgID == .msgObjectRemoved {
                DispatchQueue.main.async {
                    self?.refreshDestinations()
                }
            }
        }
        guard clientStatus == noErr else { return }
        
        MIDIOutputPortCreate(midiClient, "PeanutButter Output Port" as CFString, &outputPort)
        MIDISourceCreate(midiClient, "PeanutButter MIDI Out" as CFString, &masterVirtualSource)
        
        for bus in MIDIBus.allCases {
            var endpoint: MIDIEndpointRef = 0
            let name = "PeanutButter - \(bus.rawValue)" as CFString
            if MIDISourceCreate(midiClient, name, &endpoint) == noErr {
                busVirtualSources[bus] = endpoint
            }
        }
    }
    
    /// Queries CoreMIDI for all connected hardware/software MIDI output destinations
    public func refreshDestinations() {
        var results: [MIDIOutputDestination] = [
            MIDIOutputDestination(
                id: Self.allOutputsID,
                name: "All Connected MIDI Outputs + Virtual Out",
                endpointRef: 0,
                isVirtual: true
            ),
            MIDIOutputDestination(
                id: Self.virtualOnlyID,
                name: "PeanutButter Virtual MIDI Out",
                endpointRef: masterVirtualSource,
                isVirtual: true
            )
        ]
        
        let destCount = MIDIGetNumberOfDestinations()
        for i in 0..<destCount {
            let dest = MIDIGetDestination(i)
            guard dest != 0 else { continue }
            
            let name = Self.endpointDisplayName(dest)
            if name.hasPrefix("PeanutButter") {
                continue
            }
            
            var uniqueID: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(dest, kMIDIPropertyUniqueID, &uniqueID)
            let idString = uniqueID != 0 ? "uid_\(uniqueID)" : "dest_\(i)_\(name)"
            results.append(MIDIOutputDestination(
                id: idString,
                name: name,
                endpointRef: dest,
                isVirtual: false
            ))
        }
        
        if Thread.isMainThread {
            self.availableDestinations = results
            self.validateSelectedDestination()
        } else {
            let captured = results
            DispatchQueue.main.async { [weak self] in
                self?.availableDestinations = captured
                self?.validateSelectedDestination()
            }
        }
        let clockSnapshot = results
        clockQueue.async { [weak self] in
            self?.clockEndpointsCache = clockSnapshot
        }
    }
    
    private func validateSelectedDestination() {
        if !availableDestinations.contains(where: { $0.id == selectedDestinationID }) {
            // If a specific hardware destination is connected and "all_outputs" was default, keep all_outputs
            selectedDestinationID = Self.allOutputsID
        }
    }
    
    public var selectedDestinationDisplayName: String {
        if let match = availableDestinations.first(where: { $0.id == selectedDestinationID }) {
            return match.name
        }
        return "All Connected MIDI Outputs"
    }
    
    private static func endpointDisplayName(_ endpoint: MIDIEndpointRef) -> String {
        var displayNameRef: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &displayNameRef) == noErr,
           let cfStr = displayNameRef?.takeRetainedValue() {
            let s = (cfStr as String).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { return s }
        }
        var nameRef: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &nameRef) == noErr,
           let cfStr = nameRef?.takeRetainedValue() {
            let s = (cfStr as String).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { return s }
        }
        return "MIDI Output Device"
    }
    
    /// Fires ProPresenter Playlist (`F-1` = Note 17) and/or ProPresenter Playlist Item (`F#-1` = Note 18) when a song starts
    public func fireProPresenterSongStart(playlist: Int?, playlistItem: Int?) {
        let validPlaylist = (playlist != nil && playlist! >= 1 && playlist! <= 127) ? playlist! : nil
        let validItem = (playlistItem != nil && playlistItem! >= 1 && playlistItem! <= 127) ? playlistItem! : nil
        guard validPlaylist != nil || validItem != nil else { return }
        
        if let pl = validPlaylist {
            // F-1 is MIDI Note 17 (C-2 = 0 convention: C-1 = 12, D-1 = 14, E-1 = 16, F-1 = 17)
            let plCue = MIDICue(
                time: 0,
                bus: .lyrics,
                messageType: .note,
                primaryValue: 17,
                secondaryValue: pl,
                disableLoop: false,
                cueDescription: "ProPresenter Playlist \(pl)"
            )
            fire(cue: plCue)
        }
        
        if let item = validItem {
            // F#-1 is MIDI Note 18 (ProPresenter Playlist Item)
            let delay: TimeInterval = (validPlaylist != nil) ? 0.035 : 0.0
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                let itemCue = MIDICue(
                    time: 0,
                    bus: .lyrics,
                    messageType: .note,
                    primaryValue: 18,
                    secondaryValue: item,
                    disableLoop: false,
                    cueDescription: "ProPresenter Playlist Item \(item)"
                )
                self?.fire(cue: itemCue)
            }
        }
    }
    
    /// Fires a single `MIDICue` immediately over CoreMIDI to the selected destination(s)
    public func fire(cue: MIDICue) {
        guard !disabledBuses.contains(cue.bus) else { return }
        let chOneBased = busChannels[cue.bus] ?? Int(cue.bus.defaultChannel)
        let targetDestID = busDestinationOverrides[cue.bus] ?? selectedDestinationID
        let snapshotDestinations = availableDestinations
        
        queue.async { [weak self] in
            guard let self = self else { return }
            let channelIndex = UInt8(max(0, min(15, chOneBased - 1)))
            let data1 = UInt8(max(0, min(127, cue.primaryValue)))
            let data2 = UInt8(max(0, min(127, cue.secondaryValue)))
            
            switch cue.messageType {
            case .note:
                let velocity = max(1, data2)
                let noteOnStatus: UInt8 = 0x90 | channelIndex
                self.sendRawBytes([noteOnStatus, data1, velocity], bus: cue.bus, targetDestID: targetDestID, snapshotDestinations: snapshotDestinations)
                
                // Schedule automatic Note Off after 120ms so receiving software/hardware latches cleanly
                self.queue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    let noteOffStatus: UInt8 = 0x80 | channelIndex
                    self?.sendRawBytes([noteOffStatus, data1, 0], bus: cue.bus, targetDestID: targetDestID, snapshotDestinations: snapshotDestinations)
                }
                
            case .controlChange:
                let ccStatus: UInt8 = 0xB0 | channelIndex
                self.sendRawBytes([ccStatus, data1, data2], bus: cue.bus, targetDestID: targetDestID, snapshotDestinations: snapshotDestinations)
                
            case .programChange:
                let pcStatus: UInt8 = 0xC0 | channelIndex
                self.sendRawBytes([pcStatus, data1], bus: cue.bus, targetDestID: targetDestID, snapshotDestinations: snapshotDestinations)
            }
        }
    }
    
    private func sendRawBytes(
        _ bytes: [UInt8],
        bus: MIDIBus,
        targetDestID: String,
        snapshotDestinations: [MIDIOutputDestination]
    ) {
        guard !bytes.isEmpty else { return }
        var packetList = MIDIPacketList()
        let packet = MIDIPacketListInit(&packetList)
        _ = MIDIPacketListAdd(&packetList, 1024, packet, 0, bytes.count, bytes)
        
        let sendToVirtual = (targetDestID == Self.allOutputsID || targetDestID == Self.virtualOnlyID)
        if sendToVirtual {
            if masterVirtualSource != 0 {
                MIDIReceived(masterVirtualSource, &packetList)
            }
            if let busEndpoint = busVirtualSources[bus], busEndpoint != 0 {
                MIDIReceived(busEndpoint, &packetList)
            }
        }
        
        guard outputPort != 0 else { return }
        
        if targetDestID == Self.allOutputsID {
            let destCount = MIDIGetNumberOfDestinations()
            for i in 0..<destCount {
                let dest = MIDIGetDestination(i)
                if dest != 0 {
                    let destName = Self.endpointDisplayName(dest)
                    if !destName.hasPrefix("PeanutButter") {
                        MIDISend(outputPort, dest, &packetList)
                    }
                }
            }
        } else if targetDestID != Self.virtualOnlyID {
            if let matched = snapshotDestinations.first(where: { $0.id == targetDestID }), matched.endpointRef != 0 {
                MIDISend(outputPort, matched.endpointRef, &packetList)
            }
        }
    }
    
    // MARK: - MIDI Beat Clock (24 PPQN)
    
    /// Individual MIDI destinations eligible for multi-select MIDI Clock output (Virtual Out + external hardware/software ports)
    public var clockSelectableDestinations: [MIDIOutputDestination] {
        availableDestinations.filter { $0.id != Self.allOutputsID }
    }
    
    public func toggleMIDIClockDestination(_ id: String) {
        if midiClockDestinationIDs.contains(id) {
            midiClockDestinationIDs.remove(id)
        } else {
            midiClockDestinationIDs.insert(id)
        }
    }
    
    public func selectAllMIDIClockDestinations() {
        midiClockDestinationIDs = Set(clockSelectableDestinations.map { $0.id })
    }
    
    public func clearMIDIClockDestinations() {
        midiClockDestinationIDs.removeAll()
    }
    
    /// Starts (or restarts) 24 PPQN MIDI Clock transmission with `0xFA` (Start) or `0xFB` (Continue).
    public func startMIDIClock(bpm: Double, isResume: Bool) {
        guard isMIDIClockEnabled else { return }
        let clampedBPM = max(20.0, min(300.0, bpm))
        let targetIDs = midiClockDestinationIDs
        let endpoints = availableDestinations
        
        clockQueue.async { [weak self] in
            guard let self = self else { return }
            self.clockTargetIDs = targetIDs
            self.clockEndpointsCache = endpoints
            self.clockBPM = clampedBPM
            
            self.clockTimer?.cancel()
            self.clockTimer = nil
            
            let now = mach_absolute_time()
            let startHostTime = now + self.nanosToHostTicks(3_000_000.0)
            self.nextPulseHostTime = startHostTime
            self.isClockRunning = true
            
            // 0xFB = Continue, 0xFA = Start
            self.sendClockBytes([isResume ? 0xFB : 0xFA], timestamp: startHostTime)
            self.scheduleUpcomingClockPulses(now: now)
            
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: self.clockQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in
                guard let self = self, self.isClockRunning else { return }
                self.scheduleUpcomingClockPulses(now: mach_absolute_time())
            }
            self.clockTimer = timer
            timer.resume()
        }
    }
    
    /// Dynamically updates the MIDI Clock tempo without interrupting pulse phase.
    public func updateMIDIClockTempo(_ bpm: Double) {
        let clampedBPM = max(20.0, min(300.0, bpm))
        clockQueue.async { [weak self] in
            self?.clockBPM = clampedBPM
        }
    }
    
    /// Stops MIDI Clock transmission and sends `0xFC` (Stop) if currently running.
    public func stopMIDIClock() {
        clockQueue.async { [weak self] in
            guard let self = self else { return }
            let wasRunning = self.isClockRunning
            self.isClockRunning = false
            self.clockTimer?.cancel()
            self.clockTimer = nil
            if wasRunning {
                self.sendClockBytes([0xFC], timestamp: mach_absolute_time())
            }
        }
    }
    
    /// Keeps MIDI Clock running/stopped and tempo-synced during playback ticks (e.g., if toggled mid-song or muted).
    public func syncMIDIClockPlayback(isPlayingAndUnmuted: Bool, bpm: Double, isResume: Bool = true) {
        guard isPlayingAndUnmuted && isMIDIClockEnabled else {
            stopMIDIClock()
            return
        }
        let clampedBPM = max(20.0, min(300.0, bpm))
        let targetIDs = midiClockDestinationIDs
        let endpoints = availableDestinations
        
        clockQueue.async { [weak self] in
            guard let self = self else { return }
            self.clockTargetIDs = targetIDs
            self.clockEndpointsCache = endpoints
            if self.isClockRunning {
                self.clockBPM = clampedBPM
            } else {
                // Start cleanly if MIDI Clock was just enabled or unmuted mid-playback
                DispatchQueue.main.async { [weak self] in
                    self?.startMIDIClock(bpm: clampedBPM, isResume: isResume)
                }
            }
        }
    }
    
    private func nanosToHostTicks(_ nanos: Double) -> UInt64 {
        guard timebaseInfo.numer > 0 else { return UInt64(max(1.0, nanos)) }
        let ticks = nanos * Double(timebaseInfo.denom) / Double(timebaseInfo.numer)
        return UInt64(max(1.0, ticks.rounded()))
    }
    
    private func scheduleUpcomingClockPulses(now: UInt64) {
        guard isClockRunning else { return }
        let lookaheadTicks = nanosToHostTicks(25_000_000.0) // 25ms lookahead for jitter-free CoreMIDI scheduling
        let maxLagTicks = nanosToHostTicks(120_000_000.0)
        if now > nextPulseHostTime + maxLagTicks {
            // Recover cleanly after system sleep or debugger pause without burst-firing stale pulses
            nextPulseHostTime = now
        }
        let pulseNanos = (60.0 / (max(20.0, clockBPM) * 24.0)) * 1_000_000_000.0
        let pulseTicks = nanosToHostTicks(pulseNanos)
        let horizon = now + lookaheadTicks
        
        while nextPulseHostTime <= horizon {
            sendClockBytes([0xF8], timestamp: nextPulseHostTime)
            nextPulseHostTime &+= pulseTicks
        }
    }
    
    private func sendClockBytes(_ bytes: [UInt8], timestamp: MIDITimeStamp) {
        guard !bytes.isEmpty, !clockTargetIDs.isEmpty else { return }
        var packetList = MIDIPacketList()
        let packet = MIDIPacketListInit(&packetList)
        _ = MIDIPacketListAdd(&packetList, 1024, packet, timestamp, bytes.count, bytes)
        
        if clockTargetIDs.contains(Self.virtualOnlyID), masterVirtualSource != 0 {
            MIDIReceived(masterVirtualSource, &packetList)
        }
        
        guard outputPort != 0 else { return }
        for dest in clockEndpointsCache where !dest.isVirtual && clockTargetIDs.contains(dest.id) && dest.endpointRef != 0 {
            MIDISend(outputPort, dest.endpointRef, &packetList)
        }
    }
}
