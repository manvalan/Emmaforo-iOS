import CoreBluetooth
import Foundation
import UIKit

struct BatteryStatus: Equatable {
    var percent: Int?
    var voltageMillivolts: Int?
    var chargeState: Int?
    var charging = false
    var fault = 0
    var valid = false
    var powerGood = false
    /// The board measured the percent with its MAX17048 fuel gauge (firmware after 1.0).
    var gauge = false
    /// Charge (+) or discharge (-) rate in %/h, reported only with the fuel gauge.
    var ratePercentPerHour: Double?
}

protocol BatteryStatusSource: AnyObject {
    var battery: BatteryStatus { get }
}

final class EmmaForoBluetooth: NSObject, ObservableObject, BatteryStatusSource, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let serviceUUID = CBUUID(string: "FFF0")
    private let ssidUUID = CBUUID(string: "FFF1")
    private let passwordUUID = CBUUID(string: "FFF2")
    private let applyUUID = CBUUID(string: "FFF3")
    private let scanRequestUUID = CBUUID(string: "FFF4")
    private let scanResultsUUID = CBUUID(string: "FFF5")
    private let ledCommandUUID = CBUUID(string: "FFF6")
    private let networkStatusUUID = CBUUID(string: "FFF7")
    private let ledModeUUID = CBUUID(string: "FFF8")
    private let batteryUUID = CBUUID(string: "FFF9")
    private let powerUUID = CBUUID(string: "FFFA")
    private let deviceNameUUID = CBUUID(string: "FFFB")
    private let safeChargingUUID = CBUUID(string: "FFFC")
    private let colorPresetUUID = CBUUID(string: "FFFD")
    private let serialUUID = CBUUID(string: "FFFE")
    private let firmwareVersionUUID = CBUUID(string: "FFEF")
    private let firmwareApproveUUID = CBUUID(string: "FFEE")
#if DEBUG || EMMAFORO_BATTERY_LOG
    private let batteryLogUUID = CBUUID(string: "FFED")
#endif
#if DEBUG || EMMAFORO_REMOTE
    private let remoteUUID = CBUUID(string: "FFEC")
#endif
    private let firmwareNoteURL = URL(string: "https://emmaforo.michelebigi.it/firmware/version.txt")
    private let colorPresetSize = 25
    private let lastPercentKey = "emmaforoLastBatteryPercent"

    @Published private(set) var status = "Bluetooth inattivo"
    @Published private(set) var isReady = false
    @Published private(set) var isBusy = false
    @Published private(set) var networks: [EmmaForoNetwork] = []
    @Published private(set) var connectedNetworkName: String = ""
    @Published private(set) var boardHasPassword = false
    @Published private(set) var isWifiConnected = false
    @Published private(set) var hasWifiStatus = false
    @Published private(set) var isScanningNetworks = false
    @Published private(set) var wifiEndpoint: String?
    @Published private(set) var battery = BatteryStatus()
    @Published private(set) var safeCharging = true
    @Published private(set) var chargePaused = false
    @Published private(set) var gentleCharge = false
    @Published private(set) var hasChargeReport = false
    @Published private(set) var isOutOfRange = false
    @Published private(set) var deviceName = "Emmaforo"
    @Published private(set) var serialNumber = ""
    @Published private(set) var firmwareVersion = ""
    @Published private(set) var offeredFirmware = ""
    @Published private(set) var firmwareUpdating = false
    @Published private(set) var colorPreset: Data?
    @Published private(set) var colorPresetAck = 0
#if DEBUG || EMMAFORO_BATTERY_LOG
    @Published private(set) var batteryLogAvailable = false
    @Published private(set) var batteryLogState: BatteryLogState = .idle
    private var batteryLogCharacteristic: CBCharacteristic?
    private var batteryLogSamples: [Int: BatteryLogSample] = [:]
    private var batteryLogTimeout: DispatchWorkItem?
#endif
#if DEBUG || EMMAFORO_REMOTE
    @Published private(set) var remote = RemoteStatus()
    private var remoteCharacteristic: CBCharacteristic?
#endif

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var ssidCharacteristic: CBCharacteristic?
    private var passwordCharacteristic: CBCharacteristic?
    private var applyCharacteristic: CBCharacteristic?
    private var scanRequestCharacteristic: CBCharacteristic?
    private var scanResultsCharacteristic: CBCharacteristic?
    private var ledCommandCharacteristic: CBCharacteristic?
    private var networkStatusCharacteristic: CBCharacteristic?
    private var ledModeCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    private var powerCharacteristic: CBCharacteristic?
    private var deviceNameCharacteristic: CBCharacteristic?
    private var safeChargingCharacteristic: CBCharacteristic?
    private var colorPresetCharacteristic: CBCharacteristic?
    private var serialCharacteristic: CBCharacteristic?
    private var firmwareVersionCharacteristic: CBCharacteristic?
    private var firmwareApproveCharacteristic: CBCharacteristic?
    private var scanTimeout: DispatchWorkItem?
    private var pendingDeviceName = ""
    private var pendingWrites: [(CBCharacteristic, Data)] = []
    private var pendingLED: Data?
    private var inFlight: CBCharacteristic?
    private var scanBuffer = ""
    private var scanSessionID = 0
    private var scanReadAttempts = 0
    private var scanTimeoutWorkItem: DispatchWorkItem?
    private var scanRequestSessionID: Int?
    private var scanWhenReady = false
    private var connectionRequested = false
    private var lampInFlight = false
    private var failedKnownID: UUID?
    private var serviceDiscoveryAttempts = 0
    private var yielding = false
    private var queuedLamp: (command: String, blink: Bool, level: Int)?
    private var lampWaiter: ((Bool) -> Void)?
    private var lampTimeout: DispatchWorkItem?
    private let peripheralKey = "emmaforoPeripheralID"
    private var firmwareQuietUntil: Date?
    private var firmwareReconnect: DispatchWorkItem?
    private var firmwareNoteFetched: Date?

    private var firmwareIsQuiet: Bool {
        if let until = firmwareQuietUntil, Date() < until { return true }
        return false
    }

    var firmwareUpdateWindow: Bool { firmwareIsQuiet }

    var newerFirmware: String? {
        guard let offered = versionParts(offeredFirmware), let running = versionParts(firmwareVersion) else {
            return nil
        }
        let count = max(offered.count, running.count)
        for index in 0..<count {
            let left = index < offered.count ? offered[index] : 0
            let right = index < running.count ? running[index] : 0
            if left > right { return offeredFirmware }
            if left < right { return nil }
        }
        return nil
    }

    private func versionParts(_ text: String) -> [Int]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let pieces = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        if pieces.isEmpty { return nil }
        var numbers: [Int] = []
        for piece in pieces {
            if piece.isEmpty || !piece.allSatisfy(\.isNumber) { return nil }
            guard let value = Int(piece) else { return nil }
            numbers.append(value)
        }
        return numbers
    }

    static let shared = EmmaForoBluetooth()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionShowPowerAlertKey: false
        ])
    }

    func prepareForCommand() {
        if firmwareIsQuiet { return }
        let mark = { self.lampInFlight = true; self.connectionRequested = true }
        if Thread.isMainThread {
            mark()
        } else {
            DispatchQueue.main.sync(execute: mark)
        }
    }

    func connect() {
        refreshFirmwareNote()
        if firmwareIsQuiet {
            isBusy = false
            isOutOfRange = true
            status = "Fuori portata"
            return
        }
        connectionRequested = true
        guard central.state == .poweredOn else {
            isBusy = false
            isOutOfRange = false
            status = central.state == .unauthorized ? "Consenti il Bluetooth" : "Attiva il Bluetooth"
            if central.state == .unauthorized || central.state == .poweredOff || central.state == .unsupported {
                finishLamp(false)
            }
            return
        }
        guard !isReady else { return }

        if let known = rememberedPeripheral(), known.identifier != failedKnownID {
            known.delegate = self
            peripheral = known
            if known.state == .connected {
                if central.isScanning { central.stopScan() }
                isBusy = true
                isOutOfRange = false
                if status != "Individuo i comandi..." {
                    status = "Individuo i comandi..."
                    known.discoverServices([serviceUUID])
                }
                return
            }
            if known.state != .connecting {
                central.connect(known, options: nil)
            }
        }

        status = "Cerco Emmaforo…"
        isBusy = true
        isOutOfRange = false
        if !central.isScanning {
            central.scanForPeripherals(withServices: [serviceUUID], options: nil)
        }
        armSearchTimeout()
    }

    func yieldToNetwork() {
        guard !isReady else { return }
        scanTimeout?.cancel()
        let live = peripheral?.state == .connected || peripheral?.state == .connecting
        if live {
            yielding = true
        }
        if central.state == .poweredOn {
            if central.isScanning { central.stopScan() }
            if live, let peripheral {
                central.cancelPeripheralConnection(peripheral)
            }
        }
        isBusy = false
        isOutOfRange = true
        status = "Fuori portata"
    }

    private func armSearchTimeout() {
        scanTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.isReady else { return }
            if let peripheral = self.peripheral, peripheral.state == .connected {
                peripheral.delegate = self
                self.status = "Individuo i comandi..."
                peripheral.discoverServices([self.serviceUUID])
                return
            }
            self.yieldToNetwork()
            self.finishLamp(false)
        }
        scanTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
    }

    func pauseScan() {
        if lampInFlight || lampWaiter != nil { return }
        scanTimeout?.cancel()
        guard central.state == .poweredOn else { return }
        central.stopScan()
        if !isReady {
            isBusy = false
        }
    }

    func selectNetwork() {
        if isReady {
            scanNetworks()
        } else {
            scanWhenReady = true
            connect()
        }
    }

    func refreshFirmwareNote() {
        if let fetched = firmwareNoteFetched, Date().timeIntervalSince(fetched) < 15 { return }
        guard let firmwareNoteURL else { return }
        firmwareNoteFetched = Date()
        URLSession.shared.dataTask(with: firmwareNoteURL) { [weak self] data, response, _ in
            guard let self else { return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data, let text = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async { self.firmwareNoteFetched = nil }
                return
            }
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { self.offeredFirmware = trimmed }
        }.resume()
    }

    func approveFirmware(_ version: String) {
        guard isReady, let data = version.data(using: .utf8), let firmwareApproveCharacteristic else {
            status = "Collega prima EmmaForo"
            return
        }
        firmwareUpdating = true
        let until = Date().addingTimeInterval(120)
        firmwareQuietUntil = until
        connectionRequested = false
        firmwareReconnect?.cancel()
        let reconnect = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.firmwareQuietUntil = nil
            self.connectionRequested = true
            self.connect()
        }
        firmwareReconnect = reconnect
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: reconnect)
        pendingWrites.append((firmwareApproveCharacteristic, data))
        status = "Confermo il firmware…"
        pumpWrites()
    }

    func configure(ssid: String, password: String) {
        guard isReady, let ssidData = ssid.data(using: .utf8),
              let passwordData = password.data(using: .utf8),
              let ssidCharacteristic, let passwordCharacteristic, let applyCharacteristic else {
            status = "Collega prima EmmaForo"
            return
        }
        pendingWrites.removeAll { isCredential($0.0) }
        pendingWrites.append((ssidCharacteristic, ssidData))
        pendingWrites.append((passwordCharacteristic, passwordData))
        pendingWrites.append((applyCharacteristic, Data([1])))
        status = "Salvo la rete…"
        pumpWrites()
    }

    func scanNetworks() {
        guard isReady, let peripheral, scanRequestCharacteristic != nil,
              let scanResultsCharacteristic else {
            status = "Collega prima EmmaForo"
            return
        }

        scanSessionID += 1
        let sessionID = scanSessionID
        scanReadAttempts = 0
        scanRequestSessionID = nil
        scanTimeoutWorkItem?.cancel()
        status = "Scansione reti via Bluetooth..."
        isBusy = true
        isScanningNetworks = true
        networks = []
        scanBuffer = ""

        if scanResultsCharacteristic.isNotifying {
            requestNetworkScan(sessionID: sessionID)
        } else {
            peripheral.setNotifyValue(true, for: scanResultsCharacteristic)
        }

        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isBusy, self.scanSessionID == sessionID else { return }
            self.isBusy = false
            self.isScanningNetworks = false
            self.status = "Timeout scansione reti"
            self.scanBuffer = ""
        }
        scanTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20.0, execute: timeout)
    }

    private func requestNetworkScan(sessionID: Int) {
        guard isBusy, scanSessionID == sessionID, scanRequestSessionID != sessionID,
              let scanRequestCharacteristic else { return }
        scanRequestSessionID = sessionID
        enqueue(scanRequestCharacteristic, Data([1]))
    }

    func sendLamp(command: String, blink: Bool, level: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.startLamp(command: command, blink: blink, level: level) { ok in
                    continuation.resume(returning: ok)
                }
            }
        }
    }

    private func startLamp(command: String, blink: Bool, level: Int, finish: @escaping (Bool) -> Void) {
        let previous = lampWaiter
        lampWaiter = nil
        previous?(false)
        queuedLamp = (command, blink, level)
        lampWaiter = finish
        lampTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.isReady, UIApplication.shared.applicationState != .active {
                self.central.stopScan()
                self.isBusy = false
            }
            self.finishLamp(false)
        }
        lampTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        connectionRequested = true
        if isReady {
            dispatchQueuedLamp()
        } else {
            connect()
        }
    }

    private func dispatchQueuedLamp() {
        guard isReady, ledCommandCharacteristic != nil, let queuedLamp else { return }
        setLED(led: 0, command: queuedLamp.command, blink: queuedLamp.blink,
               intervalMilliseconds: 1000, brightness: queuedLamp.level)
    }

    private func finishLamp(_ ok: Bool) {
        guard lampWaiter != nil else { return }
        lampTimeout?.cancel()
        lampTimeout = nil
        queuedLamp = nil
        lampInFlight = false
        let waiter = lampWaiter
        lampWaiter = nil
        waiter?(ok)
    }

    private func rememberedPeripheral() -> CBPeripheral? {
        guard central.state == .poweredOn,
              let raw = UserDefaults.standard.string(forKey: peripheralKey),
              let uuid = UUID(uuidString: raw) else { return nil }
        return central.retrievePeripherals(withIdentifiers: [uuid]).first
    }

    private func remember(_ peripheral: CBPeripheral) {
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: peripheralKey)
    }

    func setLED(led: Int?, command: String, blink: Bool, intervalMilliseconds: Int = 1000,
                brightness: Int = 255) {
        guard isReady, ledCommandCharacteristic != nil else {
            status = "Collega prima EmmaForo"
            return
        }
        let target = led.map(String.init) ?? "255"
        let level = min(max(brightness, 0), 255)
        let payload = "\(target),\(command),\(blink ? 1 : 0),\(intervalMilliseconds),\(level)"
        pendingLED = Data(payload.utf8)
        pumpWrites()
    }

    func readPower() {
        guard let peripheral else { return }
        if let batteryCharacteristic { peripheral.readValue(for: batteryCharacteristic) }
        if let safeChargingCharacteristic { peripheral.readValue(for: safeChargingCharacteristic) }
    }

    func writeColorPreset(_ data: Data) {
        guard isReady, data.count == colorPresetSize, let colorPresetCharacteristic else { return }
        pendingWrites.removeAll { $0.0.uuid == colorPresetUUID }
        enqueue(colorPresetCharacteristic, data)
    }

    func setSafeCharging(_ enabled: Bool) {
        safeCharging = enabled
        guard isReady, let safeChargingCharacteristic else { return }
        enqueue(safeChargingCharacteristic, Data([enabled ? 1 : 0]))
    }

    func setChargePaused(_ paused: Bool) {
        chargePaused = paused
        writePower(paused ? "pause:1" : "pause:0")
    }

    func setGentleCharge(_ gentle: Bool) {
        gentleCharge = gentle
        writePower(gentle ? "gentle:1" : "gentle:0")
    }

    func rest() {
        writePower("riposo")
    }

    func forgetNetwork() {
        configure(ssid: "", password: "")
        wifiEndpoint = nil
        connectedNetworkName = ""
        boardHasPassword = false
        hasWifiStatus = true
    }

    func applyLinkInfo(_ info: EmmaForoBoardInfo) {
        guard !isReady else { return }
        if !info.name.isEmpty { deviceName = info.name }
        connectedNetworkName = info.wifi_saved ? info.wifi : ""
        hasWifiStatus = true
        boardHasPassword = info.password_saved
        safeCharging = info.safe
        chargePaused = info.paused
        gentleCharge = info.gentle
        hasChargeReport = true
        serialNumber = info.serial
        firmwareVersion = info.firmware
        storeBattery(percent: info.percentage, voltageMillivolts: info.voltage_mv,
                     chargeState: info.charge_status, charging: info.charging, fault: info.fault,
                     valid: info.estimated, powerGood: info.power ?? false)
        if let preset = dataFromHex(info.preset), preset.count == colorPresetSize {
            colorPreset = preset
        }
        if !firmwareIsQuiet {
            firmwareUpdating = false
        }
    }

    private func dataFromHex(_ text: String) -> Data? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count == colorPresetSize * 2 else { return nil }
        var data = Data()
        data.reserveCapacity(colorPresetSize)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data.count == colorPresetSize ? data : nil
    }

    func applyRemoteBattery(_ reading: EmmaForoBattery) {
        storeBattery(percent: reading.percentage, voltageMillivolts: reading.voltage_mv,
                     chargeState: reading.charge_status, charging: reading.charging,
                     fault: reading.fault ?? 0, valid: reading.estimated ?? true,
                     powerGood: reading.power ?? false)
    }

    private func storeBattery(percent: Int, voltageMillivolts: Int?, chargeState: Int?, charging: Bool,
                              fault: Int, valid: Bool, powerGood: Bool, gauge: Bool = false,
                              ratePercentPerHour: Double? = nil) {
        let clamped = min(max(percent, 0), 100)
        let shown: Int?
        if valid {
            shown = clamped
            UserDefaults.standard.set(clamped, forKey: lastPercentKey)
        } else if battery.percent != nil {
            shown = battery.percent
        } else if let stored = UserDefaults.standard.object(forKey: lastPercentKey) as? Int,
                  (0...100).contains(stored) {
            shown = stored
        } else {
            shown = nil
        }
        battery = BatteryStatus(
            percent: shown,
            voltageMillivolts: voltageMillivolts,
            chargeState: chargeState,
            charging: charging,
            fault: fault,
            valid: valid,
            powerGood: powerGood,
            gauge: gauge,
            ratePercentPerHour: ratePercentPerHour)
    }

    private func writePower(_ command: String) {
        guard isReady, let powerCharacteristic else { return }
        enqueue(powerCharacteristic, Data(command.utf8))
    }

    private func isCredential(_ characteristic: CBCharacteristic) -> Bool {
        characteristic.uuid == ssidUUID || characteristic.uuid == passwordUUID || characteristic.uuid == applyUUID
    }

    private func enqueue(_ characteristic: CBCharacteristic, _ data: Data) {
        pendingWrites.append((characteristic, data))
        pumpWrites()
    }

    private func pumpWrites() {
        guard inFlight == nil, let peripheral else { return }
        if !pendingWrites.isEmpty {
            let next = pendingWrites.removeFirst()
            inFlight = next.0
            peripheral.writeValue(next.1, for: next.0, type: .withResponse)
            return
        }
        if let pendingLED, let ledCommandCharacteristic {
            let data = pendingLED
            self.pendingLED = nil
            inFlight = ledCommandCharacteristic
            peripheral.writeValue(data, for: ledCommandCharacteristic, type: .withResponse)
        }
    }

    func renameDevice(_ name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isReady, !cleaned.isEmpty, cleaned.utf8.count < 32,
              let deviceNameCharacteristic else {
            status = "Nome non valido o Bluetooth non collegato"
            return
        }
        pendingDeviceName = cleaned
        enqueue(deviceNameCharacteristic, Data(cleaned.utf8))
    }

    func setConfigurationLEDMode(_ enabled: Bool) {
        guard isReady, let ledModeCharacteristic else { return }
        enqueue(ledModeCharacteristic, Data((enabled ? "config" : "classic").utf8))
    }

    func refreshNetworkStatus() {
        guard let peripheral, let networkStatusCharacteristic else { return }
        peripheral.readValue(for: networkStatusCharacteristic)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            isBusy = false
            isOutOfRange = false
            status = central.state == .unauthorized ? "Consenti il Bluetooth" : "Attiva il Bluetooth"
            if central.state == .unauthorized || central.state == .poweredOff || central.state == .unsupported {
                finishLamp(false)
            }
            return
        }
        if connectionRequested, !isReady {
            connect()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard isEmmaforo(peripheral, advertisementData: advertisementData) else { return }
        if central.isScanning { central.stopScan() }
        remember(peripheral)
        self.peripheral = peripheral
        peripheral.delegate = self
        if peripheral.state == .connected {
            status = "Individuo i comandi..."
            peripheral.discoverServices([serviceUUID])
            return
        }
        if peripheral.state == .connecting {
            status = "Connessione…"
            return
        }
        scanTimeout?.cancel()
        status = "Connessione…"
        central.connect(peripheral, options: nil)
        armSearchTimeout()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        failedKnownID = peripheral.identifier
        isReady = false
        isBusy = false
        status = "Cerco Emmaforo…"
        if connectionRequested {
            connect()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if central.isScanning { central.stopScan() }
        scanTimeout?.cancel()
        failedKnownID = nil
        serviceDiscoveryAttempts = 0
        remember(peripheral)
        self.peripheral = peripheral
        peripheral.delegate = self
        isOutOfRange = false
        isBusy = true
        status = "Individuo i comandi..."
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        scanTimeout?.cancel()
        isReady = false
        isBusy = false
        isScanningNetworks = false
        hasWifiStatus = false
        inFlight = nil
        pendingLED = nil
        pendingWrites.removeAll()
        serviceDiscoveryAttempts = 0
#if DEBUG || EMMAFORO_REMOTE
        remote.available = false
        remoteCharacteristic = nil
#endif
#if DEBUG || EMMAFORO_BATTERY_LOG
        batteryLogAvailable = false
        batteryLogCharacteristic = nil
        if case .receiving = batteryLogState {
            failBatteryLog("Collegamento interrotto")
        }
#endif
        if yielding {
            yielding = false
            isOutOfRange = true
            status = "Fuori portata"
            return
        }
        isOutOfRange = false
        status = "Cerco Emmaforo…"
        if connectionRequested {
            connect()
        }
    }

    private func isEmmaforo(_ peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
        let names = [
            advertisementData[CBAdvertisementDataLocalNameKey] as? String,
            peripheral.name
        ]
        if names.contains(where: { $0?.range(of: "emmaforo", options: .caseInsensitive) != nil }) {
            return true
        }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let overflow = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        return services.contains(serviceUUID) || overflow.contains(serviceUUID)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) {
            serviceDiscoveryAttempts = 0
            var wanted = [ssidUUID, passwordUUID, applyUUID, scanRequestUUID, scanResultsUUID, ledCommandUUID, networkStatusUUID, ledModeUUID, batteryUUID, powerUUID, deviceNameUUID, safeChargingUUID, colorPresetUUID, serialUUID, firmwareVersionUUID, firmwareApproveUUID]
#if DEBUG || EMMAFORO_BATTERY_LOG
            wanted.append(batteryLogUUID)
#endif
#if DEBUG || EMMAFORO_REMOTE
            wanted.append(remoteUUID)
#endif
            peripheral.discoverCharacteristics(wanted, for: service)
            return
        }
        if serviceDiscoveryAttempts < 1 {
            serviceDiscoveryAttempts += 1
            peripheral.discoverServices([serviceUUID])
            return
        }
        status = "Fuori portata"
        isReady = false
        isBusy = false
        central.cancelPeripheralConnection(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case ssidUUID: ssidCharacteristic = characteristic
            case passwordUUID: passwordCharacteristic = characteristic
            case applyUUID: applyCharacteristic = characteristic
            case scanRequestUUID: scanRequestCharacteristic = characteristic
            case scanResultsUUID: scanResultsCharacteristic = characteristic
            case ledCommandUUID: ledCommandCharacteristic = characteristic
            case networkStatusUUID: networkStatusCharacteristic = characteristic
            case ledModeUUID: ledModeCharacteristic = characteristic
            case batteryUUID: batteryCharacteristic = characteristic
            case powerUUID: powerCharacteristic = characteristic
            case deviceNameUUID: deviceNameCharacteristic = characteristic
            case safeChargingUUID: safeChargingCharacteristic = characteristic
            case colorPresetUUID: colorPresetCharacteristic = characteristic
            case serialUUID: serialCharacteristic = characteristic
            case firmwareVersionUUID: firmwareVersionCharacteristic = characteristic
            case firmwareApproveUUID: firmwareApproveCharacteristic = characteristic
#if DEBUG || EMMAFORO_BATTERY_LOG
            case batteryLogUUID: batteryLogCharacteristic = characteristic
#endif
#if DEBUG || EMMAFORO_REMOTE
            case remoteUUID: remoteCharacteristic = characteristic
#endif
            default: break
            }
        }
        scanTimeout?.cancel()
        isOutOfRange = false
        isReady = ssidCharacteristic != nil && passwordCharacteristic != nil && applyCharacteristic != nil
        isBusy = false
        status = isReady ? "Connesso" : "Comandi incompleti"
        if isReady {
            firmwareUpdating = false
        }
        if let networkStatusCharacteristic {
            peripheral.setNotifyValue(true, for: networkStatusCharacteristic)
            peripheral.readValue(for: networkStatusCharacteristic)
        }
        if let batteryCharacteristic {
            peripheral.setNotifyValue(true, for: batteryCharacteristic)
            peripheral.readValue(for: batteryCharacteristic)
        }
        if let deviceNameCharacteristic {
            peripheral.readValue(for: deviceNameCharacteristic)
        }
        if let serialCharacteristic {
            peripheral.readValue(for: serialCharacteristic)
        }
        if let firmwareVersionCharacteristic {
            peripheral.readValue(for: firmwareVersionCharacteristic)
        }
        if let colorPresetCharacteristic {
            peripheral.readValue(for: colorPresetCharacteristic)
        }
#if DEBUG || EMMAFORO_BATTERY_LOG
        batteryLogAvailable = batteryLogCharacteristic != nil
        if let batteryLogCharacteristic {
            peripheral.setNotifyValue(true, for: batteryLogCharacteristic)
            // Lets the board stamp later samples with real time.
            enqueue(batteryLogCharacteristic, Data("time:\(Int(Date().timeIntervalSince1970))".utf8))
        }
#endif
#if DEBUG || EMMAFORO_REMOTE
        remote.available = remoteCharacteristic != nil
        if let remoteCharacteristic { peripheral.readValue(for: remoteCharacteristic) }
#endif
        if isReady && scanWhenReady {
            scanWhenReady = false
            scanNetworks()
        }
        dispatchQueuedLamp()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if inFlight?.uuid == characteristic.uuid {
            inFlight = nil
        }
#if DEBUG || EMMAFORO_REMOTE
        if characteristic.uuid == remoteUUID {
            peripheral.readValue(for: characteristic)
            pumpWrites()
            return
        }
#endif
        if characteristic.uuid == powerUUID || characteristic.uuid == safeChargingUUID {
            pumpWrites()
            return
        }
        if characteristic.uuid == colorPresetUUID {
            if error == nil && !pendingWrites.contains(where: { $0.0.uuid == colorPresetUUID }) {
                colorPresetAck += 1
            }
            pumpWrites()
            return
        }
        if characteristic.uuid == deviceNameUUID {
            if error == nil {
                deviceName = pendingDeviceName
                status = "Nome scheda aggiornato"
            } else {
                status = "Errore salvataggio nome scheda"
            }
            pumpWrites()
            return
        }
        if characteristic.uuid == scanRequestUUID {
            if error != nil {
                isBusy = false
                isScanningNetworks = false
                status = "Errore scansione reti"
            } else {
                status = "Scansione reti via Bluetooth..."
                isBusy = true
            }
            pumpWrites()
            return
        }
        if characteristic.uuid == firmwareApproveUUID {
            if error != nil {
                firmwareUpdating = false
                firmwareQuietUntil = nil
                firmwareReconnect?.cancel()
                status = "Errore conferma firmware"
            } else {
                status = "Fuori portata"
                isOutOfRange = true
                isReady = false
                yielding = true
                connectionRequested = false
                central.cancelPeripheralConnection(peripheral)
            }
            pumpWrites()
            return
        }
        if characteristic.uuid == ledCommandUUID {
            if error != nil {
                status = "Errore comando luce"
                pumpWrites()
                if isReady { finishLamp(false) }
                return
            }
            let answeredLamp = queuedLamp != nil && pendingLED == nil
            pumpWrites()
            if answeredLamp { finishLamp(true) }
            return
        }
        if isCredential(characteristic) {
            if error != nil {
                pendingWrites.removeAll { isCredential($0.0) }
                status = "Errore invio rete"
            } else if characteristic.uuid == applyUUID && !pendingWrites.contains(where: { isCredential($0.0) }) {
                status = "Rete salvata sulla scheda"
            }
            pumpWrites()
            return
        }
        pumpWrites()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == scanResultsUUID else { return }
        guard error == nil, characteristic.isNotifying else {
            isBusy = false
            isScanningNetworks = false
            scanTimeoutWorkItem?.cancel()
            status = "Errore notifiche reti"
            return
        }
        requestNetworkScan(sessionID: scanSessionID)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            if characteristic.uuid == scanResultsUUID {
                status = "Errore lettura reti"
                isBusy = false
                isScanningNetworks = false
            }
            return
        }

#if DEBUG || EMMAFORO_REMOTE
        if characteristic.uuid == remoteUUID {
            if let data = characteristic.value, let text = String(data: data, encoding: .utf8) {
                remote.apply(text)
            }
            return
        }
#endif

#if DEBUG || EMMAFORO_BATTERY_LOG
        if characteristic.uuid == batteryLogUUID {
            if let data = characteristic.value { receiveBatteryLog(data) }
            return
        }
#endif

        if characteristic.uuid == serialUUID, let data = characteristic.value,
           let text = String(data: data, encoding: .utf8) {
            serialNumber = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }

        if characteristic.uuid == firmwareVersionUUID, let data = characteristic.value,
           let text = String(data: data, encoding: .utf8) {
            firmwareVersion = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }

        if characteristic.uuid == colorPresetUUID, let data = characteristic.value, data.count == colorPresetSize {
            colorPreset = data
            return
        }

        if characteristic.uuid == networkStatusUUID, let data = characteristic.value,
           let text = String(data: data, encoding: .utf8) {
            let fields = text.split(separator: "\t", omittingEmptySubsequences: false)
            if let first = fields.first, first == "0" || first == "1" {
                isWifiConnected = first == "1"
                connectedNetworkName = fields.count > 1 ? String(fields[1]) : ""
                if fields.count > 2 {
                    wifiEndpoint = fields[2].isEmpty ? nil : "http://\(fields[2])"
                }
                boardHasPassword = fields.count > 3 && fields[3] == "1"
                hasWifiStatus = true
            } else {
                connectedNetworkName = text.trimmingCharacters(in: .whitespacesAndNewlines)
                boardHasPassword = false
                hasWifiStatus = false
            }
            return
        }

        if characteristic.uuid == batteryUUID, let data = characteristic.value,
           let text = String(data: data, encoding: .utf8) {
            let values = text.split(separator: "\t", omittingEmptySubsequences: false)
            if values.count >= 2, let percentage = Int(values[0]), let millivolts = Int(values[1]) {
                storeBattery(
                    percent: percentage,
                    voltageMillivolts: millivolts,
                    chargeState: values.count > 3 ? Int(values[3]) : nil,
                    charging: values.count > 2 && values[2] == "1",
                    fault: values.count > 4 ? Int(values[4]) ?? 0 : 0,
                    valid: values.count < 9 || values[8] == "1",
                    powerGood: values.count > 9 && values[9] == "1",
                    gauge: values.count > 10 && values[10] == "1",
                    ratePercentPerHour: values.count > 11 && values[10] == "1"
                        ? Int(values[11]).map { Double($0) / 10 } : nil)
                if values.count > 5 { safeCharging = values[5] == "1" }
                if values.count > 6 { chargePaused = values[6] == "1" }
                if values.count > 7 {
                    gentleCharge = values[7] == "1"
                    hasChargeReport = true
                }
            }
            return
        }

        if characteristic.uuid == safeChargingUUID, let data = characteristic.value, let enabled = data.first {
            safeCharging = enabled != 0
            return
        }

        if characteristic.uuid == deviceNameUUID, let data = characteristic.value,
           let name = String(data: data, encoding: .utf8), !name.isEmpty {
            deviceName = name
            return
        }

        guard characteristic.uuid == scanResultsUUID,
              let data = characteristic.value,
              let text = String(data: data, encoding: .utf8) else {
            if characteristic.uuid == scanResultsUUID {
                status = "Errore lettura reti"
                isBusy = false
                isScanningNetworks = false
            }
            return
        }

        guard !text.isEmpty else { return }
        let sessionID = scanSessionID
        scanBuffer += text

        guard scanBuffer.contains("--END--") else {
            status = "Ricevo reti..."
            return
        }

        guard self.scanSessionID == sessionID else { return }
        scanTimeoutWorkItem?.cancel()

        let payload = scanBuffer
            .replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        if let errorLine = payload.first(where: { $0.hasPrefix("--ERROR--\t") }) {
            status = "Errore scansione: \(errorLine.dropFirst("--ERROR--\t".count))"
            isBusy = false
            isScanningNetworks = false
            scanBuffer = ""
            return
        }

        networks = payload.compactMap { line in
            let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, cleaned != "--END--" else { return nil }
            let parts = cleaned.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            guard let rssi = Int(parts[1]) else { return nil }
            return EmmaForoNetwork(ssid: String(parts[0]), rssi: rssi)
        }

        status = networks.isEmpty ? "Nessuna rete trovata" : "Reti trovate"
        isBusy = false
        isScanningNetworks = false
        scanBuffer = ""
    }
}

#if DEBUG || EMMAFORO_BATTERY_LOG
// Battery log for test devices. Compiled only into Debug builds, or builds
// that add EMMAFORO_BATTERY_LOG to Active Compilation Conditions, never into
// the App Store build. The board keeps the samples in RAM; this reads them over
// Bluetooth and writes CSV and JSON files for the share sheet.

struct BatteryLogSample: Codable {
    let index: Int
    let boot: Int
    let unixTime: Int?
    let uptimeSeconds: Int?
    let voltageMillivolts: Int
    let realPercent: Double?
    let shownPercent: Double?
    let ratePercentPerHour: Double
    let chargeMilliamps: Int
    let charging: Bool
    let powerGood: Bool
    let lampOn: Bool
    let ledLoad: Int
    let wifiOn: Bool
    let bleConnected: Bool
    let resting: Bool
    let gauge: Bool
    let chargeState: Int
}

struct BatteryLogExport: Equatable {
    let csv: URL
    let json: URL
    let count: Int
}

enum BatteryLogState: Equatable {
    case idle
    case receiving(Int)
    case ready(BatteryLogExport)
    case failed(String)
}

private struct BatteryLogDocument: Encodable {
    let format = 1
    let exportedAt: String
    let deviceName: String
    let serialNumber: String
    let firmware: String
    let capacity: Int
    let periodSeconds: Int
    let boardUptimeSeconds: Int
    let currentBoot: Int
    let note = "realPercent is the cell state of charge; shownPercent is what the app shows (95% real = 100% shown)."
    let samples: [BatteryLogSample]
}

extension EmmaForoBluetooth {
    private static let logDataMarker: UInt8 = 0xB1
    private static let logEndMarker: UInt8 = 0xBE
    private static let logSampleSize = 16
    private static let realFullPercent = 95.0

    func downloadBatteryLog() {
        guard isReady, let batteryLogCharacteristic else {
            batteryLogState = .failed("Collega prima EmmaForo")
            return
        }
        if case .receiving = batteryLogState { return }
        batteryLogSamples = [:]
        batteryLogState = .receiving(0)
        armBatteryLogTimeout()
        enqueue(batteryLogCharacteristic, Data("time:\(Int(Date().timeIntervalSince1970))".utf8))
        enqueue(batteryLogCharacteristic, Data("dump".utf8))
    }

    func clearBatteryLog() {
        guard isReady, let batteryLogCharacteristic else { return }
        enqueue(batteryLogCharacteristic, Data("clear".utf8))
        batteryLogState = .idle
    }

    fileprivate func failBatteryLog(_ reason: String) {
        batteryLogTimeout?.cancel()
        batteryLogSamples = [:]
        batteryLogState = .failed(reason)
    }

    private func armBatteryLogTimeout() {
        batteryLogTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, case .receiving = self.batteryLogState else { return }
            self.failBatteryLog("La scheda non risponde")
        }
        batteryLogTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    fileprivate func receiveBatteryLog(_ data: Data) {
        guard case .receiving = batteryLogState, let marker = data.first else { return }
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        if marker == Self.logDataMarker, bytes.count >= 3 {
            armBatteryLogTimeout()
            let first = u16(1)
            var offset = 3
            var index = first
            while offset + Self.logSampleSize <= bytes.count {
                batteryLogSamples[index] = decodeRaw(bytes, at: offset, index: index)
                offset += Self.logSampleSize
                index += 1
            }
            batteryLogState = .receiving(batteryLogSamples.count)
        } else if marker == Self.logEndMarker, bytes.count >= 16 {
            batteryLogTimeout?.cancel()
            let count = u16(1)
            guard batteryLogSamples.count >= count else {
                failBatteryLog("Ricevuti \(batteryLogSamples.count) campioni su \(count)")
                return
            }
            let receivedAt = Date()
            let document = makeDocument(count: count, capacity: u16(3), period: u16(5), uptime: u32(7),
                                        boot: Int(bytes[15]), receivedAt: receivedAt)
            do {
                batteryLogState = .ready(try writeExport(document, at: receivedAt))
            } catch {
                failBatteryLog("File non scritto: \(error.localizedDescription)")
            }
        }
    }

    // Raw fields only; time and percent are resolved once the end packet says
    // which boot is current and what the board uptime is.
    private func decodeRaw(_ bytes: [UInt8], at offset: Int, index: Int) -> BatteryLogSample {
        func u16(_ at: Int) -> Int { Int(bytes[offset + at]) | Int(bytes[offset + at + 1]) << 8 }
        let time = u16(0) | u16(2) << 16
        let soc = u16(6)
        let rate = Int16(bitPattern: UInt16(u16(8)))
        let flags = bytes[offset + 12]
        let epoch = flags & 0x80 != 0
        return BatteryLogSample(
            index: index,
            boot: Int(bytes[offset + 15]),
            unixTime: epoch ? time : nil,
            uptimeSeconds: epoch ? nil : time,
            voltageMillivolts: u16(4),
            realPercent: soc == 0xFFFF ? nil : Double(soc) / 10,
            shownPercent: soc == 0xFFFF ? nil : min(100, Double(soc) / 10 * 100 / Self.realFullPercent),
            ratePercentPerHour: Double(rate) / 100,
            chargeMilliamps: u16(10),
            charging: flags & 0x01 != 0,
            powerGood: flags & 0x02 != 0,
            lampOn: flags & 0x04 != 0,
            ledLoad: Int(bytes[offset + 14]),
            wifiOn: flags & 0x08 != 0,
            bleConnected: flags & 0x10 != 0,
            resting: flags & 0x20 != 0,
            gauge: flags & 0x40 != 0,
            chargeState: Int(bytes[offset + 13]))
    }

    private func makeDocument(count: Int, capacity: Int, period: Int, uptime: Int,
                              boot: Int, receivedAt: Date) -> BatteryLogDocument {
        let phoneNow = Int(receivedAt.timeIntervalSince1970)
        let samples = (0..<count).compactMap { batteryLogSamples[$0] }.map { sample -> BatteryLogSample in
            // Samples from the current boot without a stamp get one from the
            // board uptime; earlier boots keep only their uptime.
            guard sample.unixTime == nil, sample.boot == boot, let up = sample.uptimeSeconds, up <= uptime else {
                return sample
            }
            return BatteryLogSample(
                index: sample.index, boot: sample.boot, unixTime: phoneNow - (uptime - up),
                uptimeSeconds: up, voltageMillivolts: sample.voltageMillivolts,
                realPercent: sample.realPercent, shownPercent: sample.shownPercent,
                ratePercentPerHour: sample.ratePercentPerHour, chargeMilliamps: sample.chargeMilliamps,
                charging: sample.charging, powerGood: sample.powerGood, lampOn: sample.lampOn,
                ledLoad: sample.ledLoad, wifiOn: sample.wifiOn, bleConnected: sample.bleConnected,
                resting: sample.resting, gauge: sample.gauge, chargeState: sample.chargeState)
        }
        return BatteryLogDocument(
            exportedAt: ISO8601DateFormatter().string(from: receivedAt),
            deviceName: deviceName, serialNumber: serialNumber, firmware: firmwareVersion,
            capacity: capacity, periodSeconds: period, boardUptimeSeconds: uptime, currentBoot: boot,
            samples: samples)
    }

    private func writeExport(_ document: BatteryLogDocument, at date: Date) throws -> BatteryLogExport {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmm"
        let serial = document.serialNumber.replacingOccurrences(of: ":", with: "")
        let base = "emmaforo-battery-\(serial.isEmpty ? "board" : serial)-\(stamp.string(from: date))"
        let folder = FileManager.default.temporaryDirectory
        let csvURL = folder.appendingPathComponent(base + ".csv")
        let jsonURL = folder.appendingPathComponent(base + ".json")

        let iso = ISO8601DateFormatter()
        func text(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "" }
        func flag(_ value: Bool) -> String { value ? "1" : "0" }
        var csv = "index,boot,time_iso,unix_s,uptime_s,voltage_mv,soc_real_pct,soc_shown_pct,rate_pct_per_h,"
            + "charge_ma,charging,power_good,lamp_on,led_load,wifi_on,ble_connected,resting,gauge,charge_state\n"
        for sample in document.samples {
            let time = sample.unixTime.map { iso.string(from: Date(timeIntervalSince1970: TimeInterval($0))) } ?? ""
            let columns: [String] = [
                String(sample.index), String(sample.boot), time,
                sample.unixTime.map(String.init) ?? "", sample.uptimeSeconds.map(String.init) ?? "",
                String(sample.voltageMillivolts), text(sample.realPercent), text(sample.shownPercent),
                String(format: "%.2f", sample.ratePercentPerHour), String(sample.chargeMilliamps),
                flag(sample.charging), flag(sample.powerGood), flag(sample.lampOn), String(sample.ledLoad),
                flag(sample.wifiOn), flag(sample.bleConnected), flag(sample.resting), flag(sample.gauge),
                String(sample.chargeState)
            ]
            csv += columns.joined(separator: ",") + "\n"
        }
        try Data(csv.utf8).write(to: csvURL, options: .atomic)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: jsonURL, options: .atomic)
        return BatteryLogExport(csv: csvURL, json: jsonURL, count: document.samples.count)
    }
}
#endif

#if DEBUG || EMMAFORO_REMOTE
// Remote control over Wi-Fi (USB, TWT or interval check-in). Shown only in
// test builds until the server side exists.
struct RemoteStatus: Equatable {
    var available = false
    var enabled = false
    var intervalMinutes = 10
    var mode = "off"
    var router = 0
    var brokerConnected = false

    mutating func apply(_ text: String) {
        let fields = text.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 6, fields[0] == "1" else { return }
        enabled = fields[1] == "1"
        intervalMinutes = Int(fields[2]) ?? intervalMinutes
        mode = fields[3]
        router = Int(fields[4]) ?? 0
        brokerConnected = fields[5] == "1"
    }

    var summary: String {
        guard enabled else { return "Spento" }
        let link: String
        switch mode {
        case "usb": link = "Sul caricatore: sempre collegato"
        case "twt": link = "A batteria con router Wi‑Fi 6 (TWT)"
        case "interval": link = "A batteria: controllo ogni \(intervalMinutes) min"
        default: link = "In attesa"
        }
        return brokerConnected ? link + ", server collegato" : link
    }

    var routerText: String {
        switch router {
        case 2: return "Wi‑Fi 6 con TWT"
        case 1: return "Senza TWT"
        default: return "Non ancora provato"
        }
    }
}

extension EmmaForoBluetooth {
    func setRemote(enabled: Bool) {
        writeRemote(enabled ? "on" : "off")
    }

    func setRemoteInterval(minutes: Int) {
        writeRemote("interval:\(min(max(minutes, 1), 60))")
    }

    func setRemoteBroker(uri: String, user: String, password: String) {
        writeRemote("broker:\(uri)")
        writeRemote("user:\(user)")
        writeRemote("pass:\(password)")
    }

    private func writeRemote(_ command: String) {
        guard isReady, let remoteCharacteristic else { return }
        enqueue(remoteCharacteristic, Data(command.utf8))
    }
}
#endif
