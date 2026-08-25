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
    private lazy var supportDirectory: URL = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = root.appendingPathComponent("Score", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()
    private var autosaveURL: URL { supportDirectory.appendingPathComponent("autosave.score") }
    private var takeURL: URL { supportDirectory.appendingPathComponent("latest-take.caf") }
    private var serializationBuffer = Data(count: 4 * 1024 * 1024)

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
        (view as? ScoreMetalView)?.onAutosave = { [weak self] in self?.saveAutosave() }
        midi.onMessage = { [weak self] status, data1, data2 in
            self?.audio.monitor(status: status, data1: data1, data2: data2)
            score_ios_midi(DispatchTime.now().uptimeNanoseconds, status, data1, data2)
        }
        _ = midi.start()
        startLibraryAcceptanceIfRequested()
        startAcceptancePlaybackIfRequested()
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
        default: break
        }
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
