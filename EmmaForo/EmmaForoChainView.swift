import SwiftUI
import UIKit

private let chainDefaultsKey = "emmaforoChainSteps"
private let chainRepeatKey = "emmaforoChainRepeat"
private let voicePhrasesKey = "emmaforoVoicePhrases"

/// Every sound the board knows, with the names the app gives them.
private func soundChoices(_ phrases: [String]) -> [(Int, String)] {
    var choices: [(Int, String)] = [(0, "Nessuno")] + SoundStatus.tones
    for slot in 0..<SoundStatus.voiceSlots {
        let phrase = slot < phrases.count ? phrases[slot] : ""
        choices.append((SoundStatus.voiceFirst + slot, phrase.isEmpty ? "Messaggio \(slot + 1)" : "“\(phrase)”"))
    }
    return choices
}

private func loadPhrases() -> [String] {
    let stored = UserDefaults.standard.stringArray(forKey: voicePhrasesKey) ?? []
    return (0..<SoundStatus.voiceSlots).map { $0 < stored.count ? stored[$0] : "" }
}

private func seconds(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...1))) + " s"
}

struct ChainEditorView: View {
    @ObservedObject var bluetooth: EmmaForoBluetooth
    @State private var steps: [ChainStep] = []
    @State private var repeats = UserDefaults.standard.bool(forKey: chainRepeatKey)
    @State private var phrases = loadPhrases()

    var body: some View {
        Form {
            Section {
                ForEach($steps) { $step in
                    stepRow($step, number: (steps.firstIndex { $0.id == step.id } ?? 0) + 1)
                }
                .onDelete { steps.remove(atOffsets: $0) }
                .onMove { steps.move(fromOffsets: $0, toOffset: $1) }
                Button("Aggiungi colore") {
                    let last = steps.last
                    steps.append(ChainStep(red: last?.blue ?? 0.92, green: last?.red ?? 0.22,
                                           blue: last?.green ?? 0.18, fadeSeconds: 2, holdSeconds: 0))
                }
                .disabled(steps.count >= ChainState.maxSteps)
            } header: {
                Text("Passi")
            } footer: {
                Text("Ogni colore arriva sfumando dal precedente nel tempo di transizione e resta acceso per la pausa. Al massimo \(ChainState.maxSteps) colori.")
            }
            Section {
                Toggle("Ripeti", isOn: $repeats)
                Button("Avvia sulla lampada") {
                    bluetooth.startChain(steps, repeats: repeats)
                }
                .disabled(!bluetooth.isReady || steps.isEmpty || (repeats && totalSeconds == 0))
                Button("Ferma") {
                    bluetooth.stopChain()
                }
                .disabled(!bluetooth.isReady || !bluetooth.chainState.running)
            } footer: {
                if bluetooth.chainState.running {
                    Text("In corso: colore \(bluetooth.chainState.step + 1) di \(bluetooth.chainState.steps.count).")
                } else {
                    Text("Durata di un giro: \(seconds(totalSeconds)). Un colore scelto a mano ferma la catena.")
                }
            }
        }
        .navigationTitle("Catena di colori")
        .toolbar { EditButton() }
        .onAppear {
            phrases = loadPhrases()
            if let data = UserDefaults.standard.data(forKey: chainDefaultsKey),
               let stored = try? JSONDecoder().decode([ChainStep].self, from: data) {
                steps = stored
            } else if !bluetooth.chainState.steps.isEmpty {
                steps = bluetooth.chainState.steps
                repeats = bluetooth.chainState.repeats
            }
            bluetooth.refreshChain()
        }
        .onChange(of: steps) { _, value in
            if let data = try? JSONEncoder().encode(value) {
                UserDefaults.standard.set(data, forKey: chainDefaultsKey)
            }
        }
        .onChange(of: repeats) { _, value in UserDefaults.standard.set(value, forKey: chainRepeatKey) }
    }

    private var totalSeconds: Double {
        steps.reduce(0) { $0 + $1.fadeSeconds + $1.holdSeconds }
    }

    @ViewBuilder
    private func stepRow(_ step: Binding<ChainStep>, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ColorPicker("Colore \(number)", selection: Binding(
                get: { Color(red: step.wrappedValue.red, green: step.wrappedValue.green, blue: step.wrappedValue.blue) },
                set: { color in
                    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                    UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                    step.wrappedValue.red = Double(min(max(red, 0), 1))
                    step.wrappedValue.green = Double(min(max(green, 0), 1))
                    step.wrappedValue.blue = Double(min(max(blue, 0), 1))
                }
            ), supportsOpacity: false)
            Stepper(value: step.fadeSeconds, in: 0...3600, step: 0.5) {
                LabeledContent("Transizione") { Text(seconds(step.wrappedValue.fadeSeconds)).monospacedDigit() }
            }
            Stepper(value: step.holdSeconds, in: 0...3600, step: 1) {
                LabeledContent("Pausa") { Text(seconds(step.wrappedValue.holdSeconds)).monospacedDigit() }
            }
            if bluetooth.sound.available {
                Picker("Suono all'arrivo", selection: step.sound) {
                    ForEach(soundChoices(phrases), id: \.0) { Text($0.1).tag($0.0) }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct SoundsView: View {
    @ObservedObject var bluetooth: EmmaForoBluetooth
    @State private var volume = 70.0
    @State private var phrases = loadPhrases()
    @State private var maker = VoiceMaker()

    var body: some View {
        Form {
            Section {
                Slider(value: $volume, in: 0...100, step: 5) { editing in
                    if !editing { bluetooth.setVolume(Int(volume)) }
                }
                .accessibilityLabel("Volume")
            } header: {
                Text("Volume")
            } footer: {
                Text("A zero la lampada resta muta.")
            }
            Section {
                ForEach(LampSoundState.allCases) { state in
                    Picker(state.name, selection: Binding(
                        get: { bluetooth.sound.map[state.rawValue] },
                        set: { bluetooth.setSound($0, for: state) }
                    )) {
                        ForEach(soundChoices(phrases), id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
            } header: {
                Text("Quando la lampada diventa")
            } footer: {
                Text("Il suono parte quando cambi colore dall'app, dal widget o da Siri. “Altro colore” vale per tutti i colori che non sono rosso, giallo o verde.")
            }
            Section {
                ForEach(SoundStatus.tones, id: \.0) { tone in
                    Button {
                        bluetooth.playSound(tone.0)
                    } label: {
                        Label(tone.1, systemImage: "play.circle")
                    }
                }
            } header: {
                Text("Suoni della lampada")
            }
            Section {
                ForEach(0..<SoundStatus.voiceSlots, id: \.self) { slot in
                    voiceRow(slot)
                }
                if case .failed(let reason) = bluetooth.voiceUpload {
                    Text(reason).foregroundStyle(.secondary)
                }
            } header: {
                Text("Messaggi vocali")
            } footer: {
                if bluetooth.sound.voicesSupported {
                    Text("Scrivi una frase breve: la voce italiana del telefono la pronuncia e la lampada la conserva. Al massimo \(seconds(Double(bluetooth.sound.maxVoiceMilliseconds) / 1000)) per messaggio.")
                } else {
                    Text("Questa scheda non ha spazio per i messaggi vocali: va aggiornata una volta via USB. I suoni della lampada funzionano lo stesso.")
                }
            }
        }
        .navigationTitle("Suoni")
        .onAppear {
            volume = Double(bluetooth.sound.volume)
            phrases = loadPhrases()
        }
        .onChange(of: bluetooth.sound.volume) { _, value in volume = Double(value) }
        .onChange(of: phrases) { _, value in UserDefaults.standard.set(value, forKey: voicePhrasesKey) }
    }

    @ViewBuilder
    private func voiceRow(_ slot: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Messaggio \(slot + 1)", text: $phrases[slot])
            HStack(spacing: 16) {
                Button("Invia") { send(slot) }
                    .disabled(!canSend(slot))
                Button("Prova") { bluetooth.playSound(SoundStatus.voiceFirst + slot) }
                    .disabled(!bluetooth.isReady || !bluetooth.sound.hasVoice(slot))
                Button("Cancella", role: .destructive) { bluetooth.deleteVoice(slot: slot) }
                    .disabled(!bluetooth.isReady || !bluetooth.sound.hasVoice(slot))
                Spacer()
                uploadBadge(slot)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func uploadBadge(_ slot: Int) -> some View {
        switch bluetooth.voiceUpload {
        case .preparing(slot):
            ProgressView()
        case .sending(slot, let progress):
            Text("\(Int(progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
        default:
            if bluetooth.sound.hasVoice(slot) {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
            }
        }
    }

    private var uploading: Bool {
        switch bluetooth.voiceUpload {
        case .preparing, .sending: return true
        default: return false
        }
    }

    private func canSend(_ slot: Int) -> Bool {
        bluetooth.isReady && bluetooth.sound.voicesSupported && !uploading
            && !phrases[slot].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(_ slot: Int) {
        let phrase = phrases[slot].trimmingCharacters(in: .whitespacesAndNewlines)
        let maxSamples = bluetooth.sound.maxVoiceMilliseconds * Int(VoiceMaker.sampleRate) / 1000
        bluetooth.voiceUpload = .preparing(slot)
        maker.make(phrase, maxSamples: maxSamples) { samples in
            if samples.isEmpty {
                bluetooth.voiceUpload = .failed("La voce del telefono non ha prodotto audio")
            } else {
                bluetooth.uploadVoice(slot: slot, samples: samples)
            }
        }
    }
}
