import AVFoundation
import Foundation
import Speech

/// Listens for one spoken word and turns it into a lamp command. Recognition
/// stays on the phone when the device supports it; nothing is kept.
final class VoiceCommandListener: ObservableObject {
    enum State: Equatable {
        case idle
        case listening
        case heard(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "it-IT"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timeout: DispatchWorkItem?
    private var onCommand: ((String) -> Void)?

    /// Words for each command: the colors, and what one says to a traffic light.
    private static let words: [(String, [String])] = [
        ("rosso", ["rosso", "stop", "fermo", "ferma", "alt"]),
        ("giallo", ["giallo", "attenzione", "aspetta"]),
        ("verde", ["verde", "avanti", "vai", "via", "libero"]),
        ("spento", ["spento", "spegni", "spegniti", "spegnere"]),
    ]

    private static let chainStopWords: Set<String> = ["ferma", "stop", "spegni", "basta"]

    /// "catena" alone (or "avvia catena") starts the stored chain, with ferma,
    /// stop, spegni or basta it stops it, as in the Android app.
    static func command(in text: String) -> String? {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        if tokens.contains("catena") {
            return tokens.contains(where: chainStopWords.contains) ? "catena:ferma" : "catena:avvia"
        }
        for token in tokens.reversed() {
            if let match = words.first(where: { $0.1.contains(token) }) { return match.0 }
        }
        return nil
    }

    func listen(onCommand: @escaping (String) -> Void) {
        if state == .listening {
            stop()
            return
        }
        self.onCommand = onCommand
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self.state = .failed("Consenti il riconoscimento vocale nelle Impostazioni")
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        if granted { self.start() } else { self.state = .failed("Consenti il microfono nelle Impostazioni") }
                    }
                }
            }
        }
    }

    func stop() {
        timeout?.cancel()
        timeout = nil
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if state == .listening { state = .idle }
    }

    private func start() {
        guard let recognizer, recognizer.isAvailable else {
            state = .failed("Riconoscimento vocale non disponibile")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            state = .failed("Microfono non disponibile")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.contextualStrings = Self.words.flatMap(\.1)
        self.request = request
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            state = .failed("Microfono non disponibile")
            return
        }
        state = .listening
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.state == .listening else { return }
                if let text = result?.bestTranscription.formattedString, let command = Self.command(in: text) {
                    self.stop()
                    self.state = .heard(command)
                    self.onCommand?(command)
                } else if error != nil || result?.isFinal == true {
                    self.stop()
                    self.state = .failed("Non ho capito: di' rosso, giallo, verde o spento")
                }
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.state == .listening else { return }
            self.stop()
            self.state = .failed("Non ho capito: di' rosso, giallo, verde o spento")
        }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: timeout)
    }
}
