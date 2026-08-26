import Foundation
import AVFoundation
import CoreMIDI
import Network
import UIKit

final class ScoreOSCService {
    var onState: ((UInt32, String) -> Void)?
    private let queue = DispatchQueue(label: "app.score.practice.osc", qos: .userInteractive)
    private var connection: NWConnection?
    private var targetLabel = ""
    private var refreshPending = false

    deinit { connection?.cancel() }

    func configure(host: String, port: UInt16) {
        connection?.cancel()
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            onState?(2, "INVALID OSC PORT")
            return
        }
        targetLabel = "\(host):\(port)"
        let candidate = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .udp)
        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            guard let self, let candidate, candidate === self.connection else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async { self.onState?(1, self.targetLabel) }
                if self.refreshPending {
                    self.refreshPending = false
                    self.send(Self.oscMessage(address: "/refresh"))
                }
            case .failed(let error):
                DispatchQueue.main.async { self.onState?(2, "OSC ERROR: \(error.localizedDescription)") }
            case .waiting(let error):
                DispatchQueue.main.async { self.onState?(2, "OSC WAITING: \(error.localizedDescription)") }
            default: break
            }
        }
        connection = candidate
        onState?(0, "CONNECTING \(targetLabel)")
        candidate.start(queue: queue)
    }

    func send(_ payload: Data) {
        guard let connection else {
            onState?(2, "TAP SETUP / PORT 8000")
            return
        }
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.onState?(2, "OSC SEND ERROR: \(error.localizedDescription)") }
        })
    }

    func sendRefreshWhenReady() {
        refreshPending = true
        if case .ready? = connection?.state {
            refreshPending = false
            send(Self.oscMessage(address: "/refresh"))
        }
    }

    private static func oscMessage(address: String) -> Data {
        func padded(_ string: String) -> [UInt8] {
            var bytes = Array(string.utf8) + [0]
            while bytes.count % 4 != 0 { bytes.append(0) }
            return bytes
        }
        return Data(padded(address) + padded(","))
    }
}

final class ScoreAudioService {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode!
    private var microphoneInstalled = false
    private let recordingLock = NSLock()
    private var recordingFile: AVAudioFile?
    private var replayPlayer: AVAudioPlayer?

    var isOutputRunning: Bool { engine.isRunning }

    init() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                for buffer in buffers { buffer.mData?.assumingMemoryBound(to: Float.self).update(repeating: 0, count: Int(frameCount)) }
                return noErr
            }
            score_ios_audio_render(left, right, Int(frameCount), Float(format.sampleRate))
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        loadBundledPiano()
        startOutput()
    }

    private func loadBundledPiano() {
        guard let url = Bundle.main.url(forResource: "portable-grand", withExtension: "scorebank"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            NSLog("Score sampled piano bank is missing")
            return
        }
        if !loadBank(data) { NSLog("Score sampled piano bank was rejected") }
    }

    @discardableResult
    func loadBank(_ data: Data) -> Bool {
        // The Zig piano owns a zero-copy view into this bank. Stop the realtime
        // callback while the view and its backing storage are swapped.
        let restartOutput = engine.isRunning
        if restartOutput { engine.stop() }
        defer {
            if restartOutput {
                do { try engine.start() }
                catch { NSLog("Score audio output restart failed: %@", String(describing: error)) }
            }
        }
        let status = data.withUnsafeBytes { raw -> UInt32 in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return 1 }
            return score_ios_audio_load_bank(bytes, raw.count)
        }
        if status != 0 { NSLog("Score sampled piano bank rejected: %u", status) }
        return status == 0
    }

    func consume(_ events: [ScorePlaybackEvent]) {
        for event in events {
            score_ios_audio_event(event.pitch, event.velocity, event.channel, event.on)
        }
    }

    func monitor(status: UInt8, data1: UInt8, data2: UInt8) {
        score_ios_audio_midi(status, data1, data2)
    }

    private func startOutput() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            try engine.start()
        } catch {
            NSLog("Score audio output unavailable: %@", String(describing: error))
        }
    }

    func enableMicrophone(completion: @escaping (Bool) -> Void) {
        if microphoneInstalled { completion(true); return }
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard granted, let self else { completion(false); return }
                do {
                    self.engine.stop()
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
                    try session.setActive(true)
                    let input = self.engine.inputNode
                    let format = input.outputFormat(forBus: 0)
                    input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                        guard let channel = buffer.floatChannelData?[0] else { return }
                        var confidence: Float = 0
                        let pitch = score_ios_detect_pitch(channel, Int(buffer.frameLength), Float(format.sampleRate), &confidence)
                        if pitch != 255 {
                            let detectedPitch = UInt8(pitch)
                            let detectedConfidence = confidence
                            DispatchQueue.main.async { score_ios_microphone_pitch(detectedPitch, detectedConfidence) }
                        }
                        self?.recordingLock.lock()
                        if let file = self?.recordingFile { try? file.write(from: buffer) }
                        self?.recordingLock.unlock()
                    }
                    try self.engine.start()
                    self.microphoneInstalled = true
                    completion(true)
                } catch {
                    NSLog("Score microphone unavailable: %@", String(describing: error))
                    completion(false)
                }
            }
        }
    }

    func startRecording(to url: URL, completion: @escaping (Bool) -> Void) {
        enableMicrophone { [weak self] ready in
            guard ready, let self else { completion(false); return }
            do {
                let format = self.engine.inputNode.outputFormat(forBus: 0)
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                self.recordingLock.lock()
                self.recordingFile = file
                self.recordingLock.unlock()
                completion(true)
            } catch {
                completion(false)
            }
        }
    }

    func stopRecording() {
        recordingLock.lock()
        recordingFile = nil
        recordingLock.unlock()
    }

    func replay(_ url: URL) {
        replayPlayer = try? AVAudioPlayer(contentsOf: url)
        replayPlayer?.prepareToPlay()
        replayPlayer?.play()
    }
}

private func scoreMIDIRead(
    _ packetList: UnsafePointer<MIDIPacketList>,
    _ readContext: UnsafeMutableRawPointer?,
    _ sourceContext: UnsafeMutableRawPointer?
) {
    guard let readContext else { return }
    let service = Unmanaged<ScoreMIDIService>.fromOpaque(readContext).takeUnretainedValue()
    var packet = packetList.pointee.packet
    for _ in 0..<packetList.pointee.numPackets {
        let length = Int(packet.length)
        withUnsafeBytes(of: packet.data) { raw in
            var offset = 0
            while offset < length {
                let status = raw[offset]
                if status < 0x80 { break }
                let message = status & 0xf0
                let byteCount = (message == 0xc0 || message == 0xd0) ? 2 : 3
                if offset + byteCount > length { break }
                let data1 = byteCount > 1 ? raw[offset + 1] : 0
                let data2 = byteCount > 2 ? raw[offset + 2] : 0
                DispatchQueue.main.async { service.receive(status: status, data1: data1, data2: data2) }
                offset += byteCount
            }
        }
        packet = MIDIPacketNext(&packet).pointee
    }
    _ = sourceContext
}

final class ScoreMIDIService {
    var onMessage: ((UInt8, UInt8, UInt8) -> Void)?
    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var virtualSource = MIDIEndpointRef()
    private var started = false

    private static func endpointName() -> String {
        let device = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableID = UIDevice.current.identifierForVendor?.uuidString.replacingOccurrences(of: "-", with: "").prefix(8) ?? "UNKNOWN"
        return "Score Controller — \(device.isEmpty ? "iPad" : device) [\(stableID)]"
    }

    private static func objectName(_ object: MIDIObjectRef) -> String {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &value) == noErr,
              let value else { return "unnamed" }
        return value.takeRetainedValue() as String
    }

    private static var acceptanceDiagnosticsEnabled: Bool {
        ProcessInfo.processInfo.environment["SCORE_IOS_CONTROLLER_ACCEPTANCE"] == "1"
    }

    fileprivate func receive(status: UInt8, data1: UInt8, data2: UInt8) {
        if Self.acceptanceDiagnosticsEnabled {
            NSLog(
                "Score iPad MIDI received status=%02X data1=%u data2=%u",
                status,
                data1,
                data2
            )
        }
        onMessage?(status, data1, data2)
    }

    /// Prefer direct CoreMIDI endpoints (USB IDAM, hardware, Bluetooth) over
    /// the network session. Sending the same event through both paths makes a
    /// DAW produce doubled notes when it has both endpoints connected.
    private func outputDestinations() -> [MIDIEndpointRef] {
        let networkDestination = MIDINetworkSession.default().destinationEndpoint()
        var direct: [MIDIEndpointRef] = []
        var network: [MIDIEndpointRef] = []
        for index in 0..<MIDIGetNumberOfDestinations() {
            let destination = MIDIGetDestination(index)
            guard destination != 0 else { continue }
            if destination == networkDestination {
                network.append(destination)
            } else {
                direct.append(destination)
            }
        }
        return direct.isEmpty ? network : direct
    }

    deinit {
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if outputPort != 0 { MIDIPortDispose(outputPort) }
        if virtualSource != 0 { MIDIEndpointDispose(virtualSource) }
        if client != 0 { MIDIClientDispose(client) }
    }

    @discardableResult
    func start() -> Bool {
        if started { return true }
        let endpointName = Self.endpointName()
        let clientStatus = MIDIClientCreate("Score \(endpointName)" as CFString, nil, nil, &client)
        let sourceStatus = clientStatus == noErr
            ? MIDISourceCreateWithProtocol(client, endpointName as CFString, ._1_0, &virtualSource)
            : OSStatus(-1)
        // iPadOS may reject app-created virtual sources with
        // kMIDINotPermitted.  That source is only a convenience for hosts
        // which expose virtual endpoints; the real USB and Network MIDI paths
        // are destinations reached through the output port below.
        let inputStatus = clientStatus == noErr
            ? MIDIInputPortCreate(client, "Score Input" as CFString, scoreMIDIRead, Unmanaged.passUnretained(self).toOpaque(), &inputPort)
            : OSStatus(-1)
        let outputStatus = inputStatus == noErr
            ? MIDIOutputPortCreate(client, "Score Output" as CFString, &outputPort)
            : OSStatus(-1)
        guard clientStatus == noErr,
              inputStatus == noErr,
              outputStatus == noErr else {
            if Self.acceptanceDiagnosticsEnabled {
                NSLog(
                    "Score iPad MIDI start failed client=%d source=%d input=%d output=%d",
                    clientStatus,
                    sourceStatus,
                    inputStatus,
                    outputStatus
                )
            }
            return false
        }
        let network = MIDINetworkSession.default()
        network.connectionPolicy = .anyone
        network.isEnabled = true
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            if source != 0 && source != virtualSource { MIDIPortConnectSource(inputPort, source, nil) }
        }
        if Self.acceptanceDiagnosticsEnabled {
            NSLog(
                "Score iPad MIDI start source=%@ virtual_status=%d sources=%u destinations=%u",
                endpointName,
                sourceStatus,
                MIDIGetNumberOfSources(),
                MIDIGetNumberOfDestinations()
            )
            for index in 0..<MIDIGetNumberOfDestinations() {
                let destination = MIDIGetDestination(index)
                NSLog("Score iPad MIDI destination[%u]=%@", index, Self.objectName(destination))
            }
        }
        started = true
        return true
    }

    func send(status: UInt8, data1: UInt8, data2: UInt8) {
        guard started else { return }
        let timestamp: MIDITimeStamp = 0

        // Keep both representations available. Apple's IDAM endpoint is a
        // MIDI 1.0 destination and has proven more reliable with its native
        // MIDIPacketList path, while MIDI 2 endpoints require UMP events.
        var legacyPacket = MIDIPacket()
        legacyPacket.timeStamp = timestamp
        legacyPacket.length = 3
        legacyPacket.data.0 = status
        legacyPacket.data.1 = data1
        legacyPacket.data.2 = data2
        var packetList = MIDIPacketList(numPackets: 1, packet: legacyPacket)

        var eventList = MIDIEventList()
        let packet = MIDIEventListInit(&eventList, ._1_0)
        // MIDI 1.0 channel voice messages use a 32-bit Universal MIDI Packet:
        // message type 0x2, group 0, followed by the original three bytes.
        var word = UInt32(0x2) << 28
            | UInt32(status) << 16
            | UInt32(data1) << 8
            | UInt32(data2)
        _ = MIDIEventListAdd(
            &eventList,
            MemoryLayout<MIDIEventList>.size,
            packet,
            timestamp,
            1,
            &word
        )
        let receivedStatus = virtualSource == 0 ? OSStatus(-1) : MIDIReceivedEventList(virtualSource, &eventList)
        let destinations = outputDestinations()
        if Self.acceptanceDiagnosticsEnabled {
            NSLog(
                "Score iPad MIDI send status=%02X data1=%u data2=%u virtual=%d targets=%u",
                status,
                data1,
                data2,
                receivedStatus,
                destinations.count
            )
        }
        for (index, destination) in destinations.enumerated() {
            var protocolID: Int32 = 0
            let protocolStatus = MIDIObjectGetIntegerProperty(destination, kMIDIPropertyProtocolID, &protocolID)
            let usesMIDI2 = protocolStatus == noErr && protocolID == MIDIProtocolID._2_0.rawValue
            let sendStatus = usesMIDI2
                ? MIDISendEventList(outputPort, destination, &eventList)
                : MIDISend(outputPort, destination, &packetList)
            if Self.acceptanceDiagnosticsEnabled {
                NSLog(
                    "Score iPad MIDI sent target[%u]=%@ transport=%@ protocol=%d property_status=%d status=%d",
                    index,
                    Self.objectName(destination),
                    usesMIDI2 ? "UMP" : "MIDI1",
                    protocolID,
                    protocolStatus,
                    sendStatus
                )
            }
        }
    }
}
