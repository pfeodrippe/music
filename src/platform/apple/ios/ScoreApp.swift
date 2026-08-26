import UIKit
import UniformTypeIdentifiers

@main
final class ScoreAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = ScoreViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

final class ScoreViewController: UIViewController, UIDocumentPickerDelegate {
    private let audio = ScoreAudioService()
    private let midi = ScoreMIDIService()
    private let osc = ScoreOSCService()
    private lazy var supportDirectory: URL = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = root.appendingPathComponent("Score", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()
    private var autosaveURL: URL { supportDirectory.appendingPathComponent("autosave.score") }
    private var takeURL: URL { supportDirectory.appendingPathComponent("latest-take.caf") }
    private var serializationBuffer = Data(count: 4 * 1024 * 1024)
    private var lastControllerPreferences: Data?
    private var controllerTargetProtocol: UInt32?

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var canBecomeFirstResponder: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    override func loadView() {
        let scoreView = ScoreMetalView(frame: UIScreen.main.bounds)
        scoreView.onHostRequest = { [weak self] request in self?.handleHostRequest(request) }
        scoreView.onPlayback = { [weak self] events in
            guard let self else { return }
            self.audio.consume(events)
        }
        scoreView.onController = { [weak self] messages in self?.sendController(messages) }
        scoreView.onControllerPreferencesChanged = { [weak self] in self?.saveControllerPreferencesIfChanged() }
        // Autosave is armed only after the existing journal has been restored
        // in viewDidAppear. CADisplayLink can render before that callback; an
        // eagerly installed closure would overwrite a valid score with the
        // built-in tutorial on the very first frame.
        view = scoreView
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        restoreAutosave()
        restoreControllerPreferences()
        (view as? ScoreMetalView)?.onAutosave = { [weak self] in self?.saveAutosave() }
        midi.onMessage = { [weak self] status, data1, data2 in
            self?.audio.monitor(status: status, data1: data1, data2: data2)
            score_ios_midi(DispatchTime.now().uptimeNanoseconds, status, data1, data2)
        }
        _ = midi.start()
        restoreControllerProtocol()
        refreshControllerTargetForProtocol()
        startLibraryAcceptanceIfRequested()
        startAcceptancePlaybackIfRequested()
        startControllerAcceptanceIfRequested()
    }

    private func startLibraryAcceptanceIfRequested() {
        guard ProcessInfo.processInfo.environment["SCORE_IOS_LIBRARY_ACCEPTANCE"] == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            for index: UInt32 in 0..<4 {
                let status = score_ios_load_bundled(index)
                NSLog("Score iPad library acceptance index=%u status=%u", index, status)
            }
            self.saveAutosave()
            NSLog("Score iPad library acceptance complete")
        }
    }

    private func startAcceptancePlaybackIfRequested() {
        guard ProcessInfo.processInfo.environment["SCORE_IOS_ACCEPTANCE"] == "1" else { return }
        score_ios_audio_reset_diagnostics()
        score_ios_key(32, 0, 1, 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self else { return }
            NSLog(
                "Score iPad audio acceptance engine=%d events=%llu sustain_events=%llu sustain=%u nonzero_samples=%llu peak=%.6f",
                self.audio.isOutputRunning ? 1 : 0,
                score_ios_audio_event_count(),
                score_ios_audio_sustain_event_count(),
                score_ios_audio_last_sustain_value(),
                score_ios_audio_nonzero_samples(),
                score_ios_audio_peak()
            )
            score_ios_audio_finish_diagnostics()
        }
    }

    /// Physical-device acceptance uses the same accessibility activation path
    /// as VoiceOver and Switch Control. That path resolves the GPU-owned pad
    /// rectangles, feeds their down/up events through the shared Zig core, and
    /// finally drains the resulting controller packets through `sendController`.
    /// Nothing runs during a normal launch.
    private func startControllerAcceptanceIfRequested() {
        guard ProcessInfo.processInfo.environment["SCORE_IOS_CONTROLLER_ACCEPTANCE"] == "1" else { return }

        // Physical USB MIDI endpoints can be recreated while devicectl replaces
        // the running app.  Let acceptance runs opt into a longer lead-in so a
        // host-side listener can reconnect to the new CoreMIDI endpoint before
        // the first deterministic pad event.  Normal launches never use this.
        let configuredDelay = Double(
            ProcessInfo.processInfo.environment["SCORE_IOS_CONTROLLER_ACCEPTANCE_DELAY"] ?? ""
        )
        let leadIn = max(configuredDelay ?? 0.75, 0.25)

        let controllerView: UInt32 = 33
        let customBank: UInt32 = 67
        let firstPad: UInt32 = 70
        let pattern: [UInt32] = [
            firstPad + 0,  // kick, MIDI 36
            firstPad + 6,  // closed hi-hat, MIDI 42
            firstPad + 2,  // snare, MIDI 38
            firstPad + 6,
            firstPad + 0,
            firstPad + 6,
            firstPad + 2,
            firstPad + 10, // open hi-hat, MIDI 46
        ]

        DispatchQueue.main.asyncAfter(deadline: .now() + leadIn) {
            score_ios_accessibility_activate(controllerView)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + leadIn + 0.25) {
            score_ios_accessibility_activate(customBank)
        }
        for (index, pad) in pattern.enumerated() {
            let downAt = leadIn + 0.6 + Double(index) * 0.28
            let pointerID = UInt32(10_000 + index)
            DispatchQueue.main.asyncAfter(deadline: .now() + downAt) {
                guard let point = Self.controllerAcceptancePoint(id: pad) else {
                    NSLog("Score iPad controller acceptance missing pad=%u", pad - firstPad + 1)
                    return
                }
                // Accessibility activation intentionally completes a button
                // action immediately. A DAW recorder needs a realistic note
                // duration, so physical acceptance drives the same Zig pointer
                // path as a 90 ms finger strike instead.
                score_ios_pointer(1, 2, pointerID, point.x, point.y, 1, 0, 18, 0, 0)
                NSLog("Score iPad controller acceptance pad=%u", pad - firstPad + 1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + downAt + 0.09) {
                guard let point = Self.controllerAcceptancePoint(id: pad) else { return }
                score_ios_pointer(2, 2, pointerID, point.x, point.y, 0, 0, 0, 0, 0)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + leadIn + 0.6 + Double(pattern.count) * 0.28) {
            NSLog("Score iPad controller acceptance complete")
        }
    }

    private static func controllerAcceptancePoint(id: UInt32) -> (x: Float, y: Float)? {
        let count = Int(score_ios_accessibility_count())
        guard count > 0, let items = score_ios_accessibility_items() else { return nil }
        for index in 0..<count where items[index].id == id {
            var item = items[index]
            let rect = withUnsafeBytes(of: &item.rect) { raw in
                Array(raw.bindMemory(to: Float.self).prefix(4))
            }
            guard rect.count == 4 else { return nil }
            return (rect[0] + rect[2] * 0.5, rect[1] + rect[3] * 0.5)
        }
        return nil
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: " ", modifierFlags: [], action: #selector(keyCommand(_:))),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(keyCommand(_:))),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(keyCommand(_:))),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(keyCommand(_:))),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(keyCommand(_:))),
            UIKeyCommand(input: "+", modifierFlags: [], action: #selector(keyCommand(_:))),
            UIKeyCommand(input: "-", modifierFlags: [], action: #selector(keyCommand(_:))),
            UIKeyCommand(input: "\u{8}", modifierFlags: [], action: #selector(keyCommand(_:))),
        ]
    }

    @objc private func keyCommand(_ command: UIKeyCommand) {
        let key: UInt32
        switch command.input {
        case " ": key = 32
        case UIKeyCommand.inputUpArrow: key = 265
        case UIKeyCommand.inputDownArrow: key = 264
        case UIKeyCommand.inputLeftArrow: key = 263
        case UIKeyCommand.inputRightArrow: key = 262
        case "+": key = 43
        case "-": key = 45
        default: key = 8
        }
        score_ios_key(key, 0, 1, 0)
    }

    private func handleHostRequest(_ request: UInt32) {
        switch request {
        case 1: presentImporter()
        case 2: score_ios_set_host_status(midi.start() ? 4 : 5)
        case 3:
            audio.enableMicrophone { ready in score_ios_set_host_status(ready ? 4 : 5) }
        case 4: presentExporter()
        case 5: presentTakeExporter()
        case 6:
            audio.startRecording(to: takeURL) { ready in score_ios_set_host_status(ready ? 4 : 5) }
        case 7:
            audio.stopRecording()
            score_ios_set_host_status(6)
        case 8: audio.replay(takeURL)
        case 9: presentInstrumentImporter()
        case 11: presentControllerSetup()
        default: break
        }
    }

    private func sendController(_ messages: [ScoreControllerMessage]) {
        for message in messages {
            if message.kind == 1 {
                osc.send(message.payload)
            } else if message.kind == 2, message.payload.count >= 3 {
                midi.send(status: message.payload[0], data1: message.payload[1], data2: message.payload[2])
            }
        }
    }

    private func restoreControllerTarget() {
        osc.onState = { [weak self] status, label in
            guard self != nil else { return }
            Self.publishControllerTarget(status: status, label: label)
        }
        let defaults = UserDefaults.standard
        let environment = ProcessInfo.processInfo.environment
        if let host = environment["SCORE_OSC_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty {
            let configuredPort = UInt16(environment["SCORE_OSC_PORT"] ?? "") ?? 8000
            // A devicectl-configured physical device should remain usable on
            // its next ordinary launch, without requiring the setup dialog.
            defaults.set(host, forKey: "ScoreOSC.host")
            defaults.set(Int(configuredPort), forKey: "ScoreOSC.port")
            osc.configure(host: host, port: configuredPort)
            return
        }
        guard let host = defaults.string(forKey: "ScoreOSC.host"), !host.isEmpty else {
            Self.publishControllerTarget(status: 0, label: "TAP SETUP / PORT 8000")
            return
        }
        let storedPort = defaults.integer(forKey: "ScoreOSC.port")
        osc.configure(host: host, port: UInt16(storedPort == 0 ? 8000 : storedPort))
    }

    private func refreshControllerTargetForProtocol() {
        let protocolValue = score_ios_controller_protocol()
        guard controllerTargetProtocol != protocolValue else { return }
        controllerTargetProtocol = protocolValue
        if protocolValue == 0 {
            Self.publishControllerTarget(status: 1, label: "MIDI / USB")
        } else {
            restoreControllerTarget()
        }
    }

    private func restoreControllerProtocol() {
        let defaults = UserDefaults.standard
        let configured = ProcessInfo.processInfo.environment["SCORE_IOS_CONTROLLER_PROTOCOL"]?.lowercased()
        if configured == "midi" {
            defaults.set(0, forKey: "ScoreController.protocol")
        } else if configured == "osc" {
            defaults.set(1, forKey: "ScoreController.protocol")
        }
        // A fresh install must take the direct, low-latency path without
        // requiring the user to discover and toggle the protocol control.
        if defaults.object(forKey: "ScoreController.protocol") == nil {
            defaults.set(0, forKey: "ScoreController.protocol")
        }
        let value = defaults.integer(forKey: "ScoreController.protocol")
        guard value == 0 || value == 1 else { return }
        _ = score_ios_set_controller_protocol(UInt32(value))
    }

    private func presentControllerSetup() {
        if score_ios_controller_protocol() == 0 {
            let alert = UIAlertController(
                title: "MIDI Controller Output",
                message: "USB MIDI is the default low-latency path. Connect this iPad by cable, select it in Audio MIDI Setup, and press Enable. In Bitwig, use iPad – All Channels as the instrument track input.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        let defaults = UserDefaults.standard
        let alert = UIAlertController(
            title: "Controller Output",
            message: "For Bitwig, install DrivenByMoss → add Open Sound Control. Enter this Mac’s IP or .local name; its default receive port is 8000. MIDI mode uses CoreMIDI or a configured Network MIDI session.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "Mac IP or hostname, e.g. 192.168.1.20"
            field.text = defaults.string(forKey: "ScoreOSC.host")
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.keyboardType = .URL
        }
        alert.addTextField { field in
            field.placeholder = "8000"
            let stored = defaults.integer(forKey: "ScoreOSC.port")
            field.text = String(stored == 0 ? 8000 : stored)
            field.keyboardType = .numberPad
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save & Test", style: .default) { [weak self, weak alert] _ in
            guard let self, let fields = alert?.textFields, fields.count == 2 else { return }
            let host = fields[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let portValue = UInt16(fields[1].text ?? "") ?? 8000
            guard !host.isEmpty else {
                Self.publishControllerTarget(status: 2, label: "OSC HOST REQUIRED")
                return
            }
            defaults.set(host, forKey: "ScoreOSC.host")
            defaults.set(Int(portValue), forKey: "ScoreOSC.port")
            self.osc.configure(host: host, port: portValue)
            self.osc.sendRefreshWhenReady()
        })
        present(alert, animated: true)
    }

    private static func publishControllerTarget(status: UInt32, label: String) {
        let bytes = Array(label.utf8.prefix(48))
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            score_ios_set_controller_target(status, base, buffer.count)
        }
    }

    private func controllerPreferences() -> Data? {
        var data = Data(count: 1024)
        let length = data.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return score_ios_serialize_controller(base, raw.count)
        }
        guard length > 0 else { return nil }
        data.count = length
        return data
    }

    private func saveControllerPreferencesIfChanged() {
        UserDefaults.standard.set(Int(score_ios_controller_protocol()), forKey: "ScoreController.protocol")
        refreshControllerTargetForProtocol()
        guard let data = controllerPreferences(), data != lastControllerPreferences else { return }
        lastControllerPreferences = data
        UserDefaults.standard.set(data, forKey: "ScoreController.preferences")
    }

    private func restoreControllerPreferences() {
        guard let data = UserDefaults.standard.data(forKey: "ScoreController.preferences") else {
            lastControllerPreferences = controllerPreferences()
            return
        }
        let status = data.withUnsafeBytes { raw -> UInt32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 1 }
            return score_ios_restore_controller(base, raw.count)
        }
        lastControllerPreferences = status == 0 ? data : controllerPreferences()
    }

    private func presentImporter() {
        let identifiers = ["musicxml", "xml", "mxl", "mid", "midi", "score"]
        let types = identifiers.compactMap { UTType(filenameExtension: $0) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types.isEmpty ? [.data] : types, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    private func presentInstrumentImporter() {
        let type = UTType(filenameExtension: "scorebank") ?? .data
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [type], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    private func presentExporter() {
        guard let data = exportMusicXML() else { score_ios_set_host_status(3); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("score.musicxml")
        do {
            try data.write(to: url, options: .atomic)
            let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            picker.delegate = self
            present(picker, animated: true)
            score_ios_set_host_status(8)
        } catch {
            score_ios_set_host_status(3)
        }
    }

    private func presentTakeExporter() {
        guard let data = exportTakeMidi() else { score_ios_set_host_status(3); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("score-take.mid")
        do {
            try data.write(to: url, options: .atomic)
            let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            picker.delegate = self
            present(picker, animated: true)
            score_ios_set_host_status(8)
        } catch {
            score_ios_set_host_status(3)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            score_ios_set_host_status(3)
            return
        }
        if url.pathExtension.lowercased() == "scorebank" {
            score_ios_set_host_status(audio.loadBank(data) ? 13 : 14)
            return
        }
        let kind: UInt32
        switch url.pathExtension.lowercased() {
        case "mid", "midi": kind = 2
        case "score": kind = 3
        case "mxl": kind = 4
        default: kind = 1
        }
        let result = data.withUnsafeBytes { raw -> UInt32 in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return 2 }
            return score_ios_import(bytes, raw.count, kind)
        }
        score_ios_set_host_status(result == 0 ? 2 : 3)
        if result == 0 { saveAutosave() }
    }

    private func serialize() -> Data? {
        let length = serializationBuffer.withUnsafeMutableBytes { raw -> Int in
            guard let pointer = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return score_ios_serialize(pointer, raw.count)
        }
        guard length > 0 else { return nil }
        return Data(serializationBuffer.prefix(length))
    }

    private func exportMusicXML() -> Data? {
        var data = Data(count: 4 * 1024 * 1024)
        let length = data.withUnsafeMutableBytes { raw -> Int in
            guard let pointer = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return score_ios_export_musicxml(pointer, raw.count)
        }
        guard length > 0 else { return nil }
        data.removeSubrange(length..<data.count)
        return data
    }

    private func exportTakeMidi() -> Data? {
        var data = Data(count: 4 * 1024 * 1024)
        let length = data.withUnsafeMutableBytes { raw -> Int in
            guard let pointer = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return score_ios_export_take_midi(pointer, raw.count)
        }
        guard length > 0 else { return nil }
        data.removeSubrange(length..<data.count)
        return data
    }

    private func saveAutosave() {
        guard let data = serialize() else { return }
        try? data.write(to: autosaveURL, options: .atomic)
    }

    private func restoreAutosave() {
        guard let data = try? Data(contentsOf: autosaveURL) else { return }
        let result = data.withUnsafeBytes { raw -> UInt32 in
            guard let pointer = raw.bindMemory(to: UInt8.self).baseAddress else { return 2 }
            return score_ios_restore(pointer, raw.count)
        }
        if result == 0 { score_ios_set_host_status(7) }
    }
}
