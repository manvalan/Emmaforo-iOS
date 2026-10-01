import EmmaForoShared
import SwiftUI
import WidgetKit

private struct Light: Identifiable {
    let id: String
    let name: String
    let red: Double
    let green: Double
    let blue: Double
    var color: Color { Color(red: red, green: green, blue: blue) }
    var command: String { id }
}

private struct LampColor: Codable, Identifiable, Equatable {
    var id = UUID()
    var red: Double
    var green: Double
    var blue: Double

    var color: Color { Color(red: red, green: green, blue: blue) }
    var command: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()),
               Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}

private struct ColorDisc: View {
    let color: Color
    var filled: Bool
    var blinking: Bool
    var size: CGFloat

    var body: some View {
        ZStack {
            if filled && blinking {
                Circle().strokeBorder(color, lineWidth: size * 0.11)
                Circle().strokeBorder(color, lineWidth: size * 0.07)
                    .padding(size * 0.24)
            } else if filled {
                Circle().fill(color)
            } else {
                Circle().strokeBorder(color, lineWidth: 2)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct ExclusivePress<Content: View>: View {
    var allowsClear: Bool
    var onSingle: () -> Void
    var onDouble: () -> Void
    var onLong: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var armed = false
    @State private var longFired = false
    @State private var taps = 0
    @State private var wait: Task<Void, Never>?
    @State private var hold: Task<Void, Never>?

    var body: some View {
        content()
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in arm() }
                    .onEnded { _ in release() }
            )
    }

    private func arm() {
        guard !armed else { return }
        armed = true
        longFired = false
        hold?.cancel()
        hold = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, armed else { return }
            longFired = true
            wait?.cancel()
            wait = nil
            taps = 0
            if allowsClear { onLong() }
        }
    }

    private func release() {
        hold?.cancel()
        hold = nil
        let wasLong = longFired
        armed = false
        if wasLong { return }
        taps += 1
        if taps >= 2 {
            wait?.cancel()
            wait = nil
            taps = 0
            onDouble()
            return
        }
        wait?.cancel()
        wait = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            taps = 0
            wait = nil
            onSingle()
        }
    }
}

private let colorSlotCount = 8
private let colorDefaultsKey = "emmaforoLightColors"
private let colorDirtyKey = "emmaforoColorsDirty"

private let lights = [
    Light(id: "rosso", name: "Rosso", red: 0.92, green: 0.22, blue: 0.18),
    Light(id: "giallo", name: "Giallo", red: 0.96, green: 0.72, blue: 0.12),
    Light(id: "verde", name: "Verde", red: 0.18, green: 0.72, blue: 0.34)
]

private struct PaletteColor: Identifiable {
    let id: String
    let name: String
    let red: Double
    let green: Double
    let blue: Double
    var color: Color { Color(red: red, green: green, blue: blue) }
    var command: String {
        if id == "rosso" || id == "giallo" || id == "verde" { return id }
        return String(format: "#%02X%02X%02X", Int((red * 255).rounded()),
                      Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}

private let lampPalette: [PaletteColor] = [
    PaletteColor(id: "rosso", name: "Rosso", red: 0.92, green: 0.22, blue: 0.18),
    PaletteColor(id: "arancio", name: "Arancio", red: 0.98, green: 0.45, blue: 0.08),
    PaletteColor(id: "ambra", name: "Ambra", red: 0.98, green: 0.62, blue: 0.12),
    PaletteColor(id: "giallo", name: "Giallo", red: 0.96, green: 0.72, blue: 0.12),
    PaletteColor(id: "lime", name: "Lime", red: 0.62, green: 0.86, blue: 0.16),
    PaletteColor(id: "verde", name: "Verde", red: 0.18, green: 0.72, blue: 0.34),
    PaletteColor(id: "menta", name: "Menta", red: 0.20, green: 0.82, blue: 0.62),
    PaletteColor(id: "ciano", name: "Ciano", red: 0.10, green: 0.78, blue: 0.86),
    PaletteColor(id: "azzurro", name: "Azzurro", red: 0.25, green: 0.58, blue: 0.98),
    PaletteColor(id: "blu", name: "Blu", red: 0.16, green: 0.32, blue: 0.90),
    PaletteColor(id: "indaco", name: "Indaco", red: 0.28, green: 0.18, blue: 0.62),
    PaletteColor(id: "viola", name: "Viola", red: 0.52, green: 0.20, blue: 0.82),
    PaletteColor(id: "magenta", name: "Magenta", red: 0.90, green: 0.12, blue: 0.52),
    PaletteColor(id: "rosa", name: "Rosa", red: 0.98, green: 0.45, blue: 0.62),
    PaletteColor(id: "bianco-caldo", name: "Bianco caldo", red: 1.0, green: 0.78, blue: 0.48),
    PaletteColor(id: "bianco", name: "Bianco", red: 1.0, green: 1.0, blue: 1.0)
]

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var bluetooth = EmmaForoBluetooth.shared
    @AppStorage("emmaforoStationURL") private var stationURL = ""
    @AppStorage("emmaforoLightLevel") private var lightLevel = 100.0
    @State private var tab = 0
    @State private var selectedLight: String?
    @State private var blink = false
    @State private var pendingCommand: (command: String, blink: Bool)?
    @State private var lastCommand: String?
    @State private var lastBlink = false
    @State private var singleTap: Task<Void, Never>?
    @State private var wifiSSID = ""
    @State private var wifiPassword = ""
    @State private var confirmRest = false
    @State private var confirmFirmware = false
    @State private var boardResting = false
    @State private var colorSlots: [LampColor?] = Array(repeating: nil, count: colorSlotCount)
    @State private var colorsDirty = false
    @State private var editingColorID: UUID?
    @State private var selectedSlotID: UUID?
    @State private var selectedPaletteID: String?
    @State private var colorEditQuiet = false
    @State private var mixRed = 0.92
    @State private var mixGreen = 0.22
    @State private var mixBlue = 0.18
    @State private var wifiUp = false

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { semaphore.navigationTitle("Emmaforo") }
                .tabItem { Label("Semaforo", systemImage: "circle.circle") }
                .tag(0)
            NavigationStack { infoTab.navigationTitle("Info") }
                .tabItem { Label("Info", systemImage: "info.circle") }
                .tag(1)
            NavigationStack { colorsTab.navigationTitle("Colori") }
                .tabItem { Label("Colori", systemImage: "paintpalette") }
                .tag(2)
            NavigationStack { configurationTab.navigationTitle("Configurazione") }
                .tabItem { Label("Configurazione", systemImage: "gearshape") }
                .tag(3)
        }
        .tint(.primary)
        .onAppear {
            bluetooth.connect()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                bluetooth.connect()
            } else if phase == .background {
                bluetooth.pauseScan()
            }
        }
        .onChange(of: bluetooth.isReady) { _, ready in
            if ready && colorsDirty {
                bluetooth.writeColorPreset(colorPresetPayload())
            }
            guard ready, let pending = pendingCommand else { return }
            pendingCommand = nil
            bluetooth.setLED(led: 0, command: pending.command, blink: pending.blink,
                             intervalMilliseconds: 1000, brightness: brightnessByte)
            if tab == 1 || tab == 3 { bluetooth.readPower() }
        }
        .onChange(of: bluetooth.isOutOfRange) { _, outOfRange in
            guard outOfRange else { return }
            Task { await deliverPendingRemotely() }
            Task { await refreshBoardInfo() }
        }
        .onChange(of: tab) { _, value in
            if value == 1 { readPowerOnce() }
            if value == 2 { loadColors() }
            if value == 3 { readPowerOnce() }
            if value == 0 || value == 1 || value == 3 {
                Task { await refreshBoardInfo() }
            }
        }
        .task {
            while !Task.isCancelled {
                await refreshBoardInfo()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
        .onAppear {
            colorsDirty = UserDefaults.standard.bool(forKey: colorDirtyKey)
            loadColors()
        }
        .onChange(of: bluetooth.colorPreset) { _, data in
            guard let data else { return }
            applyBoardPreset(data)
        }
        .onChange(of: bluetooth.colorPresetAck) { _, _ in
            colorsDirty = false
            UserDefaults.standard.set(false, forKey: colorDirtyKey)
        }
        .onReceive(bluetooth.$wifiEndpoint) { endpoint in
            guard let endpoint, !endpoint.isEmpty else { return }
            stationURL = endpoint
            LampSnapshot.saveStation(endpoint)
        }
    }

    private var connectionLine: String {
        if boardResting { return "In riposo" }
        if bluetooth.isReady { return "Connesso" }
        if wifiUp { return "Connesso via WiFi" }
        if bluetooth.isOutOfRange { return "Fuori portata" }
        return bluetooth.status
    }

    private func batteryGlyph(percent: Int?, charging: Bool) -> String {
        let name: String
        switch percent ?? -1 {
        case ..<0: name = "battery.0percent"
        case ..<13: name = "battery.0percent"
        case ..<38: name = "battery.25percent"
        case ..<63: name = "battery.50percent"
        case ..<88: name = "battery.75percent"
        default: name = "battery.100percent"
        }
        return charging ? "\(name).bolt" : name
    }

    private var semaphore: some View {
        VStack(alignment: .leading, spacing: 36) {
            HStack(alignment: .firstTextBaseline) {
                Text(connectionLine)
                Spacer(minLength: 12)
                HStack(spacing: 4) {
                    Image(systemName: batteryGlyph(percent: bluetooth.battery.percent,
                                                    charging: bluetooth.battery.charging))
                    if let percent = bluetooth.battery.percent {
                        Text("\(percent)%")
                            .monospacedDigit()
                    }
                }
                .accessibilityLabel(bluetooth.battery.percent.map { "\($0) percento" } ?? "Batteria")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            VStack(spacing: 28) {
                ForEach(lights) { light in
                    let selected = selectedLight == light.id && !boardResting
                    ColorDisc(color: boardResting ? light.color.opacity(0.32) : light.color,
                              filled: selected, blinking: selected && blink, size: 88)
                        .contentShape(Circle())
                        .onTapGesture { tapLight(light) }
                        .accessibilityLabel(light.name)
                        .accessibilityAddTraits(.isButton)
                }
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 8) {
                Text("Intensità luminosa")
                Slider(value: Binding(
                    get: { lightLevel },
                    set: { newValue in
                        lightLevel = newValue
                        applyLiveBrightness()
                    }
                ), in: 0...100, step: 1)
                Text("Regola la luce accesa adesso.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemGroupedBackground))
        .overlay {
            if boardResting {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { wakeFromRest() }
            }
        }
    }

    private var wifiNetworks: [EmmaForoNetwork] {
        var best: [String: EmmaForoNetwork] = [:]
        for network in bluetooth.networks {
            if let current = best[network.ssid], current.rssi >= network.rssi { continue }
            best[network.ssid] = network
        }
        return best.values.sorted { $0.rssi > $1.rssi }
    }

    private var infoTab: some View {
        Form {
            Section {
                LabeledContent("Nome") {
                    Text(bluetooth.deviceName)
                }
                LabeledContent("Wi‑Fi") {
                    Text(wifiStoredSummary)
                }
                LabeledContent("Ricarica sicura") {
                    Text(chargeSummary(bluetooth.safeCharging))
                }
                LabeledContent("Pausa ricarica") {
                    Text(chargeSummary(bluetooth.chargePaused))
                }
                LabeledContent("Corrente di carica") {
                    Text(bluetooth.hasChargeReport ? (bluetooth.gentleCharge ? "Gentile" : "Normale") : "—")
                }
                Text(chargerNotice)
                if bluetooth.battery.charging {
                    Text("In ricarica")
                    LabeledContent("Durata ricarica stimata") {
                        Text(chargeDurationText)
                    }
                } else if bluetooth.chargePaused || safeChargeHolding || safeWindowHolding {
                    Text("Ricarica in pausa")
                } else {
                    Text("—")
                }
                LabeledContent("Colori") {
                    Text("\(savedColorCount) di 8")
                }
                LabeledContent("Numero di serie") {
                    Text(bluetooth.serialNumber.isEmpty ? "—" : bluetooth.serialNumber)
                        .monospaced()
                }
                LabeledContent("Firmware") {
                    Text(bluetooth.firmwareVersion.isEmpty ? "—" : bluetooth.firmwareVersion)
                        .monospaced()
                }
                if bluetooth.firmwareUpdating {
                    Text("Firmware in aggiornamento")
                }
                if let newer = bluetooth.newerFirmware, !bluetooth.firmwareUpdating {
                    Text("È disponibile il firmware \(newer) in emmaforo.michelebigi.it/firmware.")
                    Button("Aggiorna") {
                        confirmFirmware = true
                    }
                    .disabled(!bluetooth.isReady)
                }
                Button("Riposo") {
                    confirmRest = true
                }
                .disabled(!bluetooth.isReady || boardResting)
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Michele Bigi")
                    Text("© 2026 Michele Bigi")
                    Text("Apache License 2.0")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .confirmationDialog("Mettere in riposo?", isPresented: $confirmRest, titleVisibility: .visible) {
            Button("Riposo") {
                boardResting = true
                bluetooth.rest()
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Il controller dorme e resta svegliabile da Bluetooth.")
        }
        .confirmationDialog("Aggiornare il firmware?", isPresented: $confirmFirmware, titleVisibility: .visible) {
            Button("Aggiorna") {
                if let newer = bluetooth.newerFirmware {
                    bluetooth.approveFirmware(newer)
                }
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("La scheda scarica solo questa versione sulla rete salvata e si riavvia.")
        }
        .onAppear { bluetooth.refreshFirmwareNote() }
    }

    private var mixPreview: Color {
        Color(red: mixRed, green: mixGreen, blue: mixBlue)
    }

    private var colorsTab: some View {
        VStack(spacing: 48) {
            ColorDisc(color: mixPreview, filled: true, blinking: blink && lastCommand == mixedCommand, size: 72)
            VStack(spacing: 22) {
                Slider(value: $mixRed, in: 0...1)
                    .tint(Color(red: 0.92, green: 0.22, blue: 0.18))
                    .accessibilityLabel("Rosso")
                Slider(value: $mixGreen, in: 0...1)
                    .tint(Color(red: 0.18, green: 0.72, blue: 0.34))
                    .accessibilityLabel("Verde")
                Slider(value: $mixBlue, in: 0...1)
                    .tint(Color(red: 0.22, green: 0.45, blue: 0.95))
                    .accessibilityLabel("Blu")
            }
            .onChange(of: mixRed) { _, _ in writeSelectedSlot() }
            .onChange(of: mixGreen) { _, _ in writeSelectedSlot() }
            .onChange(of: mixBlue) { _, _ in writeSelectedSlot() }
            HStack(spacing: 6) {
                ForEach(0..<colorSlotCount, id: \.self) { index in
                    colorSlotDisc(index)
                        .frame(maxWidth: .infinity)
                }
            }
            VStack(spacing: 10) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<8, id: \.self) { column in
                            paletteDisc(lampPalette[row * 8 + column])
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 36)
        .padding(.top, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var configurationTab: some View {
        Form {
            Section {
                LabeledContent("Rete salvata") {
                    Text(savedNetworkName)
                }
                if bluetooth.boardHasPassword {
                    LabeledContent("Password") {
                        Text("••••••••")
                            .monospaced()
                    }
                }
            } header: {
                Text("Wi‑Fi")
            }
            Section {
                if bluetooth.isScanningNetworks {
                    HStack {
                        ProgressView()
                        Text("Cerco reti…")
                    }
                } else if wifiNetworks.isEmpty {
                    Text("Premi Cerca per vedere le reti.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(wifiNetworks) { network in
                        Button {
                            wifiSSID = network.ssid
                        } label: {
                            HStack {
                                Text(network.ssid)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if wifiSSID == network.ssid {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            Section {
                SecureField("Password", text: $wifiPassword)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !bluetooth.connectedNetworkName.isEmpty {
                        Text("Sulla scheda: \(bluetooth.connectedNetworkName)")
                    }
                    Text("Si imposta una volta. Resta sulla scheda anche dopo lo spegnimento.")
                    if bluetooth.status == "Salvo la rete…" || bluetooth.status == "Rete salvata sulla scheda"
                        || bluetooth.status == "Errore invio rete" {
                        Text(bluetooth.status)
                    }
                }
            }
            Section {
                Button("Cerca") { bluetooth.selectNetwork() }
                    .disabled(bluetooth.isScanningNetworks)
                Button("Salva") {
                    bluetooth.configure(ssid: wifiSSID, password: wifiPassword)
                }
                .disabled(!bluetooth.isReady || wifiSSID.isEmpty)
                Button("Azzera rete", role: .destructive) {
                    wifiSSID = ""
                    wifiPassword = ""
                    stationURL = ""
                    LampSnapshot.saveStation("")
                    bluetooth.forgetNetwork()
                }
                .disabled(!bluetooth.isReady)
            }
            Section {
                LabeledContent("Stima") {
                    Text(batteryPercentText).monospacedDigit()
                }
                LabeledContent("Tensione") {
                    Text(voltageText).monospacedDigit()
                }
                LabeledContent("Stato") {
                    Text(chargeStatusText)
                }
                Text(chargerNotice)
            } header: {
                Text("Batteria")
            } footer: {
                Text("La percentuale è una stima, non una misura.")
            }
            Section {
                Toggle("Ricarica sicura", isOn: Binding(
                    get: { bluetooth.safeCharging },
                    set: { bluetooth.setSafeCharging($0) }
                ))
                .disabled(!bluetooth.isReady)
                Toggle("Pausa ricarica", isOn: Binding(
                    get: { bluetooth.chargePaused },
                    set: { bluetooth.setChargePaused($0) }
                ))
                .disabled(!bluetooth.isReady)
                Picker("Corrente di carica", selection: Binding(
                    get: { bluetooth.gentleCharge },
                    set: { value in
                        bluetooth.setGentleCharge(value)
                        if !bluetooth.isReady && wifiUp {
                            Task { await postChargeCurrent(gentle: value) }
                        }
                    }
                )) {
                    Text("Gentile").tag(true)
                    Text("Normale").tag(false)
                }
                .disabled(!bluetooth.isReady && !wifiUp)
            } footer: {
                Text("Ricarica sicura: pausa al 95%, riprende al 20%.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var batteryPercentText: String {
        guard let percent = bluetooth.battery.percent else { return "—" }
        return "\(percent)%"
    }

    private var voltageText: String {
        guard let millivolts = bluetooth.battery.voltageMillivolts, millivolts > 0 else { return "—" }
        return String(format: "%.2f V", Double(millivolts) / 1000)
    }

    private var chargeStatusText: String {
        switch bluetooth.battery.chargeState {
        case 0: return "Non in carica"
        case 1: return "Pre-carica"
        case 2: return "Carica veloce"
        case 3: return "Carica completata"
        default: return bluetooth.battery.charging ? "In carica" : "—"
        }
    }

    private var safeChargeHolding: Bool {
        guard bluetooth.safeCharging, !bluetooth.chargePaused, bluetooth.battery.valid,
              let percent = bluetooth.battery.percent, percent >= 95,
              !bluetooth.battery.charging else { return false }
        return true
    }

    private var safeWindowHolding: Bool {
        guard bluetooth.safeCharging, !bluetooth.chargePaused, !bluetooth.battery.charging,
              bluetooth.battery.powerGood else { return false }
        guard bluetooth.battery.valid, let percent = bluetooth.battery.percent else { return true }
        return percent > 20
    }

    private var chargerNotice: String {
        let fault = bluetooth.battery.fault
        if fault == 0 {
            return safeChargeHolding ? "Ricarica sicura: in pausa al 95%." : "Nessun guasto"
        }
        if fault & 0x08 != 0 {
            return "La tensione della batteria è troppo alta."
        }
        switch (fault >> 4) & 0x3 {
        case 1: return "L'ingresso di alimentazione non è valido."
        case 2: return "Il caricatore si è fermato per temperatura."
        case 3: return "Il timer di sicurezza della carica è scaduto."
        default: break
        }
        switch fault & 0x7 {
        case 0x6: return "La batteria è troppo calda."
        case 0x5: return "La batteria è troppo fredda."
        case 0x2: return "La batteria è tiepida."
        case 0x3: return "La batteria è fresca."
        default: break
        }
        if fault & 0x40 != 0 {
            return "L'uscita boost del caricatore è sovraccarica."
        }
        if fault & 0x80 != 0 {
            return "Il timer di controllo del caricatore è scaduto."
        }
        return "Registro guasti del caricatore, valore \(fault)."
    }

    private var brightnessByte: Int {
        Int((min(max(lightLevel, 0), 100) / 100 * 255).rounded())
    }

    private func wakeFromRest() {
        guard boardResting else { return }
        boardResting = false
        singleTap?.cancel()
        singleTap = nil
        let command = lastCommand ?? selectedLight
        guard let command else { return }
        sendLight(command: command, blink: lastCommand == nil ? blink : lastBlink)
    }

    private func tapLight(_ light: Light) {
        if boardResting {
            wakeFromRest()
            return
        }
        if singleTap != nil {
            singleTap?.cancel()
            singleTap = nil
            blink.toggle()
            selectedLight = light.id
            sendLight(command: light.id, blink: blink)
            return
        }
        singleTap = Task {
            try? await Task.sleep(nanoseconds: 280_000_000)
            if Task.isCancelled { return }
            singleTap = nil
            if selectedLight == light.id {
                selectedLight = nil
                sendLight(command: "spento", blink: false)
            } else {
                selectedLight = light.id
                sendLight(command: light.id, blink: blink)
            }
        }
    }

    private var savedColorCount: Int {
        colorSlots.compactMap { $0 }.count
    }

    private var savedNetworkName: String {
        guard bluetooth.hasWifiStatus else { return "—" }
        return bluetooth.connectedNetworkName.isEmpty ? "Nessuna" : bluetooth.connectedNetworkName
    }

    private var wifiStoredSummary: String {
        guard bluetooth.hasWifiStatus else { return "—" }
        return bluetooth.connectedNetworkName.isEmpty ? "Non salvata" : "Salvata"
    }

    private func chargeSummary(_ enabled: Bool) -> String {
        bluetooth.hasChargeReport ? (enabled ? "Attiva" : "Spenta") : "—"
    }

    private var chargeDurationText: String {
        guard bluetooth.hasChargeReport, let percent = bluetooth.battery.percent else { return "—" }
        let target = bluetooth.safeCharging ? 95 : 100
        let remaining = max(0, target - percent)
        let current = bluetooth.gentleCharge ? 512 : 2048
        let minutesTotal = (remaining * 900 * 60 + (current * 100) / 2) / (current * 100)
        return "\(minutesTotal / 60) h \(minutesTotal % 60) min"
    }

    private var mixedCommand: String {
        String(format: "#%02X%02X%02X", Int((mixRed * 255).rounded()),
               Int((mixGreen * 255).rounded()), Int((mixBlue * 255).rounded()))
    }

    private var lampIsOn: Bool {
        guard let lastCommand else { return false }
        return lastCommand != "spento"
    }

    private func colorSlotDisc(_ index: Int) -> some View {
        let lamp = colorSlots.indices.contains(index) ? colorSlots[index] : nil
        let selected = slotIsSelected(lamp)
        return ExclusivePress(allowsClear: lamp != nil, onSingle: { chooseSlot(index, blinkOn: nil) },
                              onDouble: { chooseSlot(index, blinkOn: !blink) }, onLong: { clearSlot(index) }) {
            Group {
                if let lamp {
                    ColorDisc(color: lamp.color, filled: true, blinking: selected && blink, size: 28)
                        .accessibilityLabel("Colore salvato")
                } else {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1.5)
                        .frame(width: 28, height: 28)
                        .accessibilityLabel("Posto libero")
                }
            }
            .frame(width: 34, height: 34)
            .overlay {
                if selected {
                    Circle().strokeBorder(Color.primary, lineWidth: 3)
                }
            }
        }
    }

    private func paletteDisc(_ swatch: PaletteColor) -> some View {
        let selected = paletteIsSelected(swatch)
        return ExclusivePress(allowsClear: false, onSingle: { choosePalette(swatch, blinkOn: nil) },
                              onDouble: { choosePalette(swatch, blinkOn: !blink) }, onLong: {}) {
            ColorDisc(color: swatch.color, filled: true, blinking: selected && blink, size: 28)
                .frame(width: 34, height: 34)
                .overlay {
                    if selected {
                        Circle().strokeBorder(Color.primary, lineWidth: 3)
                    }
                }
                .accessibilityLabel(swatch.name)
        }
    }

    private func slotIsSelected(_ lamp: LampColor?) -> Bool {
        guard lampIsOn, selectedPaletteID == nil, let lamp, let selectedSlotID else { return false }
        return lamp.id == selectedSlotID
    }

    private func paletteIsSelected(_ swatch: PaletteColor) -> Bool {
        guard lampIsOn, selectedSlotID == nil, let selectedPaletteID else { return false }
        return selectedPaletteID == swatch.id
    }

    private var activeLampCommand: String? {
        lastCommand ?? selectedLight
    }

    private func focusSlot(_ lamp: LampColor) {
        selectedSlotID = lamp.id
        selectedPaletteID = nil
        editingColorID = lamp.id
        assignMix(red: lamp.red, green: lamp.green, blue: lamp.blue)
    }

    private func focusPalette(_ swatch: PaletteColor) {
        selectedPaletteID = swatch.id
        selectedSlotID = nil
    }

    private func assignMix(red: Double, green: Double, blue: Double) {
        colorEditQuiet = true
        mixRed = red
        mixGreen = green
        mixBlue = blue
        DispatchQueue.main.async { colorEditQuiet = false }
    }

    private func materializeSlot(_ index: Int) -> LampColor? {
        guard colorSlots.indices.contains(index) else { return nil }
        if let lamp = colorSlots[index] { return lamp }
        let lamp = LampColor(red: mixRed, green: mixGreen, blue: mixBlue)
        colorSlots[index] = lamp
        storeColors()
        return lamp
    }

    private func chooseSlot(_ index: Int, blinkOn: Bool?) {
        if let blinkOn {
            blink = blinkOn
            guard let lamp = materializeSlot(index) else { return }
            focusSlot(lamp)
            selectedLight = nil
            sendLight(command: lamp.command, blink: blink)
            return
        }
        if lampIsOn, let lamp = colorSlots.indices.contains(index) ? colorSlots[index] : nil,
           lamp.id == selectedSlotID {
            selectedSlotID = nil
            selectedPaletteID = nil
            selectedLight = nil
            sendLight(command: "spento", blink: false)
            return
        }
        guard let lamp = materializeSlot(index) else { return }
        focusSlot(lamp)
        selectedLight = nil
        sendLight(command: lamp.command, blink: blink)
    }

    private func choosePalette(_ swatch: PaletteColor, blinkOn: Bool?) {
        let named = swatch.id == "rosso" || swatch.id == "giallo" || swatch.id == "verde"
        if let blinkOn {
            blink = blinkOn
            focusPalette(swatch)
            selectedLight = named ? swatch.id : nil
            sendLight(command: swatch.command, blink: blink)
            return
        }
        if lampIsOn, selectedPaletteID == swatch.id {
            selectedSlotID = nil
            selectedPaletteID = nil
            selectedLight = nil
            sendLight(command: "spento", blink: false)
            return
        }
        focusPalette(swatch)
        selectedLight = named ? swatch.id : nil
        sendLight(command: swatch.command, blink: blink)
    }

    private func clearSlot(_ index: Int) {
        guard colorSlots.indices.contains(index), let lamp = colorSlots[index] else { return }
        let wasOnLamp = slotIsSelected(lamp)
        if editingColorID == lamp.id { editingColorID = nil }
        if selectedSlotID == lamp.id { selectedSlotID = nil }
        colorSlots[index] = nil
        storeColors()
        guard wasOnLamp else { return }
        selectedSlotID = nil
        selectedPaletteID = nil
        selectedLight = nil
        sendLight(command: "spento", blink: false)
    }

    private func writeSelectedSlot() {
        guard !colorEditQuiet, let editingColorID,
              let index = colorSlots.firstIndex(where: { $0?.id == editingColorID }),
              var lamp = colorSlots[index] else { return }
        let previous = lamp.command
        lamp.red = mixRed
        lamp.green = mixGreen
        lamp.blue = mixBlue
        colorSlots[index] = lamp
        storeColors()
        if selectedPaletteID == nil, selectedSlotID == lamp.id, lastCommand == previous {
            selectedLight = nil
            sendLight(command: lamp.command, blink: blink)
        }
    }

    private func applyLiveBrightness() {
        guard let command = activeLampCommand else { return }
        sendLight(command: command, blink: lastBlink)
    }

    private func colorPresetPayload() -> Data {
        var bytes = [UInt8](repeating: 0, count: 25)
        for index in 0..<min(colorSlotCount, colorSlots.count) {
            guard let lamp = colorSlots[index] else { continue }
            bytes[0] |= UInt8(1 << index)
            let offset = 1 + index * 3
            bytes[offset] = UInt8(clamping: Int((lamp.red * 255).rounded()))
            bytes[offset + 1] = UInt8(clamping: Int((lamp.green * 255).rounded()))
            bytes[offset + 2] = UInt8(clamping: Int((lamp.blue * 255).rounded()))
        }
        return Data(bytes)
    }

    private func decodePreset(_ data: Data) -> [LampColor?] {
        let bytes = [UInt8](data)
        var slots: [LampColor?] = []
        for index in 0..<colorSlotCount {
            if bytes[0] & UInt8(1 << index) == 0 {
                slots.append(nil)
                continue
            }
            let offset = 1 + index * 3
            slots.append(LampColor(
                red: Double(bytes[offset]) / 255,
                green: Double(bytes[offset + 1]) / 255,
                blue: Double(bytes[offset + 2]) / 255))
        }
        return slots
    }

    private func applyBoardPreset(_ data: Data) {
        guard data.count == 25 else { return }
        if colorsDirty {
            bluetooth.writeColorPreset(colorPresetPayload())
            return
        }
        let decoded = decodePreset(data)
        let boardCount = decoded.compactMap { $0 }.count
        if boardCount == 0 && colorSlots.contains(where: { $0 != nil }) {
            colorsDirty = true
            UserDefaults.standard.set(true, forKey: colorDirtyKey)
            bluetooth.writeColorPreset(colorPresetPayload())
            return
        }
        colorSlots = decoded
        if let editingColorID, !colorSlots.contains(where: { $0?.id == editingColorID }) {
            self.editingColorID = nil
        }
        if let selectedSlotID, !colorSlots.contains(where: { $0?.id == selectedSlotID }) {
            self.selectedSlotID = nil
        }
        saveColorsLocally()
    }

    private func loadColors() {
        guard let data = UserDefaults.standard.data(forKey: colorDefaultsKey) else {
            colorSlots = Array(repeating: nil, count: colorSlotCount)
            return
        }
        if let decoded = try? JSONDecoder().decode([LampColor?].self, from: data) {
            colorSlots = paddedSlots(decoded)
            return
        }
        if let legacy = try? JSONDecoder().decode([LampColor].self, from: data) {
            colorSlots = paddedSlots(legacy.map { Optional($0) })
            storeColors()
        }
    }

    private func paddedSlots(_ colors: [LampColor?]) -> [LampColor?] {
        var slots = Array(colors.prefix(colorSlotCount))
        if slots.count < colorSlotCount {
            slots.append(contentsOf: Array(repeating: nil, count: colorSlotCount - slots.count))
        }
        return slots
    }

    private func saveColorsLocally() {
        guard let data = try? JSONEncoder().encode(paddedSlots(colorSlots)) else { return }
        UserDefaults.standard.set(data, forKey: colorDefaultsKey)
    }

    private func storeColors() {
        saveColorsLocally()
        colorsDirty = true
        UserDefaults.standard.set(true, forKey: colorDirtyKey)
        bluetooth.writeColorPreset(colorPresetPayload())
    }

    private func sendLight(command: String, blink: Bool) {
        lastCommand = command
        if command != "spento" { lastBlink = blink }
        let on = command != "spento"
        LampSnapshot.save(on: on, color: on ? command : "", blink: blink, level: brightnessByte)
        WidgetCenter.shared.reloadAllTimelines()
        if bluetooth.isReady {
            pendingCommand = nil
            bluetooth.setLED(led: 0, command: command, blink: blink, intervalMilliseconds: 1000,
                             brightness: brightnessByte)
            return
        }
        pendingCommand = (command, blink)
        if bluetooth.isOutOfRange {
            bluetooth.yieldToNetwork()
            Task { await deliverPendingRemotely() }
            return
        }
        bluetooth.connect()
    }

    private func deliverPendingRemotely() async {
        for _ in 0..<4 {
            if bluetooth.isReady { return }
            if let pending = pendingCommand {
                let ok = await EmmaForoLink.send(command: pending.command, blink: pending.blink, level: brightnessByte)
                if ok {
                    wifiUp = true
                    pendingCommand = nil
                    let endpoint = LampSnapshot.stationURL
                    if !endpoint.isEmpty { stationURL = endpoint }
                    return
                }
            } else {
                let endpoint = await EmmaForoLink.resolve()
                if !endpoint.isEmpty {
                    wifiUp = true
                    stationURL = endpoint
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        if !bluetooth.isReady { wifiUp = false }
    }

    private func readPowerOnce() {
        if bluetooth.isReady {
            bluetooth.readPower()
        }
    }

    private func refreshBoardInfo() async {
        if bluetooth.isReady || bluetooth.firmwareUpdateWindow { return }
        var endpoint = stationURL
        if endpoint.isEmpty {
            endpoint = await EmmaForoLink.resolve()
        }
        if bluetooth.isReady || bluetooth.firmwareUpdateWindow || endpoint.isEmpty { return }
        guard let info = await EmmaForoAPI.info(endpoint: endpoint) else { return }
        if bluetooth.isReady || bluetooth.firmwareUpdateWindow { return }
        wifiUp = true
        stationURL = endpoint
        LampSnapshot.saveStation(endpoint)
        bluetooth.applyLinkInfo(info)
    }

    private func postChargeCurrent(gentle: Bool) async {
        var endpoint = stationURL
        if endpoint.isEmpty {
            endpoint = await EmmaForoLink.resolve()
        }
        guard !endpoint.isEmpty else { return }
        if await EmmaForoAPI.setCurrent(endpoint: endpoint, gentle: gentle) {
            wifiUp = true
            stationURL = endpoint
            LampSnapshot.saveStation(endpoint)
        }
    }
}
