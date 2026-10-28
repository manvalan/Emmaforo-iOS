import AVFoundation
import CoreBluetooth
import Foundation

// Color chains and the speaker of the batch3 board (firmware 1.2). The
// protocol is in the firmware README: FFEB chain, FFEA sounds, FFE9 voice data.

struct ChainStep: Codable, Identifiable, Equatable {
    var id = UUID()
    var red: Double
    var green: Double
    var blue: Double
    /// Seconds to fade from the previous color to this one.
    var fadeSeconds: Double
    /// Seconds to stay on this color before the next step.
    var holdSeconds: Double
    var sound: Int = 0
}

struct ChainState: Equatable {
    static let maxSteps = 16

    var available = false
    var running = false
    var step = 0
    var repeats = false
    var steps: [ChainStep] = []

    mutating func apply(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return }
        let count = Int(bytes[3])
        guard count <= Self.maxSteps, bytes.count >= 4 + count * 8 else { return }
        running = bytes[0] != 0
        step = Int(bytes[1])
        repeats = bytes[2] & 0x01 != 0
        steps = (0..<count).map { index in
            let at = 4 + index * 8
            func u16(_ offset: Int) -> Int { Int(bytes[at + offset]) | Int(bytes[at + offset + 1]) << 8 }
            return ChainStep(red: Double(bytes[at]) / 255, green: Double(bytes[at + 1]) / 255,
                             blue: Double(bytes[at + 2]) / 255, fadeSeconds: Double(u16(3)) / 10,
                             holdSeconds: Double(u16(5)) / 10, sound: Int(bytes[at + 7]))
        }
    }

    static func payload(_ steps: [ChainStep], repeats: Bool) -> Data {
        var bytes: [UInt8] = [0x01, repeats ? 0x01 : 0x00, UInt8(min(steps.count, maxSteps))]
        func byte(_ value: Double) -> UInt8 { UInt8(min(max((value * 255).rounded(), 0), 255)) }
        func tenths(_ seconds: Double) -> Int { min(max(Int((seconds * 10).rounded()), 0), 65535) }
        for step in steps.prefix(maxSteps) {
            let fade = tenths(step.fadeSeconds)
            let hold = tenths(step.holdSeconds)
            bytes += [byte(step.red), byte(step.green), byte(step.blue),
                      UInt8(fade & 0xFF), UInt8(fade >> 8), UInt8(hold & 0xFF), UInt8(hold >> 8),
                      UInt8(min(max(step.sound, 0), 255))]
        }
        return Data(bytes)
    }
}

enum LampSoundState: Int, CaseIterable, Identifiable {
    case rosso, giallo, verde, spento, altro

    var id: Int { rawValue }
    var key: String { ["rosso", "giallo", "verde", "spento", "altro"][rawValue] }
    var name: String { ["Rosso", "Giallo", "Verde", "Spento", "Altro colore"][rawValue] }
}

struct SoundStatus: Equatable {
    static let voiceFirst = 16
    static let voiceSlots = 5
    static let tones = [(1, "Bip"), (2, "Doppio bip"), (3, "Din-don"), (4, "Allarme"), (5, "Melodia")]

    var available = false
    var volume = 70
    var map: [Int] = Array(repeating: 0, count: LampSoundState.allCases.count)
    var voiceMask = 0
    var maxVoiceMilliseconds = 3072
    /// False on a board updated over the air: it has no partition for voices.
    var voicesSupported = false

    func hasVoice(_ slot: Int) -> Bool { voiceMask & (1 << slot) != 0 }

    mutating func apply(_ text: String) {
        let fields = text.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 6, fields[0] == "1" else { return }
        volume = Int(fields[1]) ?? volume
        let parsed = fields[2].split(separator: ",").compactMap { Int($0) }
        if parsed.count == map.count { map = parsed }
        voiceMask = Int(fields[3]) ?? 0
        maxVoiceMilliseconds = Int(fields[4]) ?? maxVoiceMilliseconds
        voicesSupported = fields[5] == "1"
    }
}

enum VoiceUpload: Equatable {
    case idle
    case preparing(Int)
    case sending(Int, Double)
    case done(Int)
    case failed(String)
}

extension EmmaForoBluetooth {
    private static let voiceChunk = 508

    func startChain(_ steps: [ChainStep], repeats: Bool) {
        guard isReady, let chainCharacteristic, !steps.isEmpty else { return }
        enqueue(chainCharacteristic, ChainState.payload(steps, repeats: repeats))
    }

    func stopChain() {
        guard isReady, let chainCharacteristic else { return }
        enqueue(chainCharacteristic, Data([0x00]))
    }

    func refreshChain() {
        guard isReady, let chainCharacteristic else { return }
        chainCharacteristic.service?.peripheral?.readValue(for: chainCharacteristic)
    }

    func setVolume(_ volume: Int) {
        sound.volume = min(max(volume, 0), 100)
        writeSound("vol:\(sound.volume)")
    }

    func setSound(_ sound: Int, for state: LampSoundState) {
        self.sound.map[state.rawValue] = sound
        writeSound("map:\(state.key):\(sound)")
    }

    func playSound(_ sound: Int) {
        writeSound("play:\(sound)")
    }

    func deleteVoice(slot: Int) {
        writeSound("clip:del:\(slot)")
    }

    /// Sends signed 8-bit samples at 8 kHz into a voice slot on the board.
    func uploadVoice(slot: Int, samples: [Int8]) {
        guard isReady, let soundCharacteristic, let voiceDataCharacteristic, !samples.isEmpty else {
            voiceUpload = .failed("Collega prima EmmaForo")
            return
        }
        let bytes = samples.map { UInt8(bitPattern: $0) }
        let chunks = stride(from: 0, to: bytes.count, by: Self.voiceChunk).map { offset -> Data in
            let end = min(offset + Self.voiceChunk, bytes.count)
            var packet = Data([UInt8(offset & 0xFF), UInt8((offset >> 8) & 0xFF),
                               UInt8((offset >> 16) & 0xFF), UInt8((offset >> 24) & 0xFF)])
            packet.append(contentsOf: bytes[offset..<end])
            return packet
        }
        voiceSlotInFlight = slot
        voiceChunksTotal = chunks.count
        voiceChunksLeft = chunks.count
        voiceUpload = .sending(slot, 0)
        enqueue(soundCharacteristic, Data("clip:begin:\(slot):\(bytes.count)".utf8))
        for chunk in chunks { enqueue(voiceDataCharacteristic, chunk) }
        let crc = String(format: "%08x", Self.crc32(bytes))
        enqueue(soundCharacteristic, Data("clip:end:\(slot):\(crc)".utf8))
    }

    func soundWriteFinished(_ characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == chainUUID {
            if error == nil { refreshChain() }
            return
        }
        if let slot = voiceSlotInFlight {
            if error != nil {
                voiceSlotInFlight = nil
                pendingWritesDrop { $0.uuid == voiceDataUUID || $0.uuid == soundUUID }
                voiceUpload = .failed("La scheda non ha accettato il messaggio")
            } else if characteristic.uuid == voiceDataUUID {
                voiceChunksLeft -= 1
                voiceUpload = .sending(slot, Double(voiceChunksTotal - voiceChunksLeft) / Double(max(voiceChunksTotal, 1)))
            } else if voiceChunksLeft == 0 {
                voiceSlotInFlight = nil
                voiceUpload = .done(slot)
                // Messages 1-3 go with rosso, giallo and verde unless those already have a sound.
                if let state = LampSoundState(rawValue: slot), slot < 3, sound.map[slot] == 0 {
                    setSound(SoundStatus.voiceFirst + slot, for: state)
                }
            }
        }
        if characteristic.uuid == soundUUID, let soundCharacteristic {
            soundCharacteristic.service?.peripheral?.readValue(for: soundCharacteristic)
        }
    }

    private func writeSound(_ command: String) {
        guard isReady, let soundCharacteristic else { return }
        enqueue(soundCharacteristic, Data(command.utf8))
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

/// Turns a phrase into the board's voice format with the phone's Italian
/// voice: 8 kHz, signed 8-bit, silence trimmed, loudness normalized.
final class VoiceMaker: NSObject, AVSpeechSynthesizerDelegate {
    static let sampleRate = 8000.0

    private let synthesizer = AVSpeechSynthesizer()
    private var source: [Float] = []
    private var sourceRate = 22050.0
    private var completion: (([Int8]) -> Void)?
    private var maxSamples = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func make(_ text: String, maxSamples: Int, completion: @escaping ([Int8]) -> Void) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "it-IT")
        source = []
        self.maxSamples = maxSamples
        self.completion = completion
        synthesizer.write(utterance) { [weak self] buffer in
            guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                DispatchQueue.main.async { self.finish() }
                return
            }
            self.sourceRate = pcm.format.sampleRate
            let frames = Int(pcm.frameLength)
            if let floats = pcm.floatChannelData?[0] {
                self.source.append(contentsOf: UnsafeBufferPointer(start: floats, count: frames))
            } else if let ints = pcm.int16ChannelData?[0] {
                self.source.append(contentsOf: UnsafeBufferPointer(start: ints, count: frames).map { Float($0) / 32768 })
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.finish() }
    }

    private func finish() {
        guard let completion else { return }
        self.completion = nil
        completion(Self.convert(source, rate: sourceRate, maxSamples: maxSamples))
    }

    static func convert(_ input: [Float], rate: Double, maxSamples: Int) -> [Int8] {
        guard !input.isEmpty, rate > 0 else { return [] }
        // Box filter over each output period: enough low-pass for speech.
        let ratio = rate / sampleRate
        let count = Int(Double(input.count) / ratio)
        var output = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let start = Int(Double(index) * ratio)
            let end = min(input.count, max(start + 1, Int(Double(index + 1) * ratio)))
            var sum: Float = 0
            for sample in start..<end { sum += input[sample] }
            output[index] = sum / Float(end - start)
        }
        let threshold: Float = 0.02
        let first = output.firstIndex { abs($0) > threshold } ?? 0
        let last = output.lastIndex { abs($0) > threshold } ?? (output.count - 1)
        guard first <= last else { return [] }
        let trimmed = output[first...last].prefix(maxSamples)
        let peak = trimmed.map(abs).max() ?? 1
        let gain = peak > 0 ? 0.95 / peak : 1
        return trimmed.map { Int8(max(-127, min(127, ($0 * gain * 127).rounded()))) }
    }
}
