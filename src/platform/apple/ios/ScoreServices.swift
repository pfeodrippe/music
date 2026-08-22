import Foundation
import AVFoundation
import CoreMIDI

private struct ScoreSynthVoice {
    var pitch: UInt8 = 0
    var channel: UInt8 = 0
    var phase: Double = 0
    var gain: Float = 0
    var envelope: Float = 0
    var releasing = false
    var active = false
    var age: UInt64 = 0
}

private final class ScoreSynthState {
    let lock = NSLock()
    var voices = Array(repeating: ScoreSynthVoice(), count: 48)
    var nextAge: UInt64 = 1
    var clickPhase: Double = 0
    var clickEnvelope: Float = 0
    var clickFrequency: Double = 1320
    var clickGain: Float = 0

    func apply(_ event: ScorePlaybackEvent) {
        lock.lock()
        defer { lock.unlock() }
        if event.on == 2 {
            for index in voices.indices where voices[index].active { voices[index].releasing = true }
            clickEnvelope = 0
        } else if event.on == 3 {
            clickPhase = 0
            clickEnvelope = 1
            clickFrequency = event.velocity >= 120 ? 1760 : 1320
            clickGain = event.velocity >= 120 ? 0.82 : 0.56
        } else if event.on == 0 {
            for index in voices.indices where voices[index].active && voices[index].pitch == event.pitch && voices[index].channel == event.channel {
                voices[index].releasing = true
            }
        } else {
            let slot = voices.firstIndex(where: { !$0.active }) ?? voices.indices.min(by: { voices[$0].age < voices[$1].age }) ?? 0
            voices[slot] = ScoreSynthVoice(
                pitch: event.pitch, channel: event.channel, phase: 0,
                gain: Float(event.velocity) / 127, envelope: 0,
                releasing: false, active: true, age: nextAge
            )
            nextAge &+= 1
        }
    }

    func render(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        for buffer in buffers {
            guard let pointer = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            pointer.update(repeating: 0, count: frames)
        }
        let clickDecay = exp(-1.0 / (sampleRate * 0.045))
        for frame in 0..<frames {
            var mixed: Float = 0
            for index in voices.indices where voices[index].active {
                let frequency = 440.0 * pow(2.0, (Double(voices[index].pitch) - 69.0) / 12.0)
                voices[index].phase += frequency / sampleRate
                voices[index].phase.formTruncatingRemainder(dividingBy: 1)
                let angle = voices[index].phase * .pi * 2
                let tone = sin(angle) + 0.32 * sin(angle * 2) + 0.12 * sin(angle * 3) + 0.045 * sin(angle * 5)
                if voices[index].releasing {
                    voices[index].envelope *= 0.99935
                    if voices[index].envelope < 0.0005 { voices[index].active = false }
                } else {
                    voices[index].envelope += (1 - voices[index].envelope) * 0.0045
                }
                mixed += Float(tone) * voices[index].gain * voices[index].envelope
            }
            if clickEnvelope > 0.0004 {
                clickPhase += clickFrequency / sampleRate
                clickPhase.formTruncatingRemainder(dividingBy: 1)
                let angle = clickPhase * .pi * 2
                mixed += Float(sin(angle) + 0.34 * sin(angle * 2.7)) * clickGain * clickEnvelope
                clickEnvelope *= Float(clickDecay)
            } else {
                clickEnvelope = 0
            }
            mixed = min(0.92, max(-0.92, mixed * 0.20))
            for buffer in buffers {
                buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = mixed
            }
        }
    }
}

final class ScoreAudioService {
    private let engine = AVAudioEngine()
    private let synth = ScoreSynthState()
    private var sourceNode: AVAudioSourceNode!
    private var microphoneInstalled = false
    private let recordingLock = NSLock()
    private var recordingFile: AVAudioFile?
    private var replayPlayer: AVAudioPlayer?

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        sourceNode = AVAudioSourceNode(format: format) { [synth] _, _, frameCount, audioBufferList in
            synth.render(UnsafeMutableAudioBufferListPointer(audioBufferList), frames: Int(frameCount), sampleRate: format.sampleRate)
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        startOutput()
    }

    func consume(_ events: [ScorePlaybackEvent]) {
        for event in events {
            synth.apply(event)
        }
    }

    func monitor(status: UInt8, data1: UInt8, data2: UInt8) {
        let message = status & 0xf0
        if message == 0x90 && data2 != 0 {
            synth.apply(ScorePlaybackEvent(pitch: data1, velocity: data2, channel: status & 0x0f, on: 1))
        } else if message == 0x80 || (message == 0x90 && data2 == 0) {
            synth.apply(ScorePlaybackEvent(pitch: data1, velocity: 0, channel: status & 0x0f, on: 0))
        }
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
                DispatchQueue.main.async { service.onMessage?(status, data1, data2) }
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
    private var started = false

    deinit {
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if outputPort != 0 { MIDIPortDispose(outputPort) }
        if client != 0 { MIDIClientDispose(client) }
    }

    @discardableResult
    func start() -> Bool {
        if started { return true }
        guard MIDIClientCreate("Score" as CFString, nil, nil, &client) == noErr,
              MIDIInputPortCreate(client, "Score Input" as CFString, scoreMIDIRead, Unmanaged.passUnretained(self).toOpaque(), &inputPort) == noErr,
              MIDIOutputPortCreate(client, "Score Output" as CFString, &outputPort) == noErr else { return false }
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            if source != 0 { MIDIPortConnectSource(inputPort, source, nil) }
        }
        started = true
        return true
    }

    func send(status: UInt8, data1: UInt8, data2: UInt8) {
        guard started else { return }
        var packetList = MIDIPacketList()
        let packet = MIDIPacketListInit(&packetList)
        let bytes = [status, data1, data2]
        bytes.withUnsafeBufferPointer { buffer in
            _ = MIDIPacketListAdd(&packetList, MemoryLayout<MIDIPacketList>.size, packet, 0, buffer.count, buffer.baseAddress!)
        }
        for index in 0..<MIDIGetNumberOfDestinations() {
            let destination = MIDIGetDestination(index)
            if destination != 0 { MIDISend(outputPort, destination, &packetList) }
        }
    }
}
