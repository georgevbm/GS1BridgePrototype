import Foundation
import Combine
@preconcurrency import CoreBluetooth

@MainActor
final class GS1BluetoothManager: NSObject, ObservableObject {
    @Published private(set) var bluetoothState = "Inicializando…"
    @Published private(set) var status = "Informe o MAC do sensor e toque em Escanear."
    @Published private(set) var peripheralName = "—"
    @Published private(set) var peripheralIdentifier = "—"
    @Published private(set) var lastPacketHex = "—"
    @Published private(set) var latestReading: GS1Reading?
    @Published private(set) var readingCount = 0
    @Published private(set) var isScanning = false
    @Published private(set) var isConnected = false

    var configuredMacAddress: String = ""
    var startIndex: Int = GS1Protocol.firstIndex

    private static let dataService = CBUUID(string: "FF30")
    private static let notifyCharacteristicUUID = CBUUID(string: "FF31")
    private static let writeCharacteristicUUID = CBUUID(string: "FF32")

    private let replyWaitNanoseconds: UInt64 = 4_000_000_000
    private let burstQuietNanoseconds: UInt64 = 900_000_000
    private let askAttemptsLimit = 3
    private let historyStallLimit = 3

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var history: [Int: GS1Reading] = [:]

    private var nextIndex = GS1Protocol.firstIndex
    private var askAttempt = 0
    private var stalls = 0
    private var sizeAtLastAsk = 0
    private var isFinished = false
    private var retryTask: Task<Void, Never>?
    private var burstTask: Task<Void, Never>?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func startScan() {
        guard central.state == .poweredOn else {
            status = "Bluetooth ainda não está disponível."
            return
        }
        guard isValidMac(configuredMacAddress) else {
            status = "MAC inválido. Use o formato AA:BB:CC:DD:EE:FF."
            return
        }

        resetSession()
        isScanning = true
        status = "Procurando um GS1 anunciando FF30…"

        // Unfiltered on purpose: the Android reference recognizes FF30 either in the
        // advertised service list or as a service-data key.
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stop() {
        central.stopScan()
        isScanning = false
        retryTask?.cancel()
        burstTask?.cancel()
        retryTask = nil
        burstTask = nil
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    var temperatureCorrectedMmol: Double? {
        guard let latestReading else { return nil }
        return GS1Protocol.temperatureCorrectedMmol(
            rawMmolPerLitre: latestReading.sensorMmolPerLitre,
            temperatureCelsius: latestReading.temperatureCelsius
        )
    }

    private func resetSession() {
        retryTask?.cancel()
        burstTask?.cancel()
        history.removeAll()
        latestReading = nil
        readingCount = 0
        lastPacketHex = "—"
        nextIndex = max(GS1Protocol.firstIndex, startIndex)
        askAttempt = 0
        stalls = 0
        sizeAtLastAsk = 0
        isFinished = false
        notifyCharacteristic = nil
        writeCharacteristic = nil
    }

    private func isValidMac(_ value: String) -> Bool {
        let parts = value.split(separator: ":")
        return parts.count == 6 && parts.allSatisfy { part in
            part.count == 2 && UInt8(part, radix: 16) != nil
        }
    }

    private func advertisementHasGS1Service(_ advertisementData: [String: Any]) -> Bool {
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        if serviceUUIDs.contains(Self.dataService) { return true }

        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        return serviceData.keys.contains(Self.dataService)
    }

    private func subscribeAndStartIfReady() {
        guard let peripheral,
              let notifyCharacteristic,
              writeCharacteristic != nil else { return }

        status = "Ativando notificações FF31…"
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
    }

    private func askFor(_ index: Int) {
        guard !isFinished,
              let peripheral,
              let writeCharacteristic else { return }

        do {
            let frame = try GS1Protocol.buildAskFrame(
                fromIndex: index,
                address: configuredMacAddress.uppercased()
            )
            nextIndex = index
            askAttempt += 1
            status = "Pedindo leituras a partir do índice #\(index)…"
            peripheral.writeValue(Data(frame), for: writeCharacteristic, type: .withResponse)
            scheduleRetry()
        } catch {
            status = "Não foi possível montar o pedido: \(error)"
        }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: replyWaitNanoseconds)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard !self.isFinished else { return }
                if self.askAttempt >= self.askAttemptsLimit {
                    self.finishHistory(reason: "o sensor parou de responder no índice #\(self.nextIndex)")
                } else {
                    self.askFor(self.nextIndex)
                }
            }
        }
    }

    private func scheduleBurstEnd() {
        burstTask?.cancel()
        burstTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: burstQuietNanoseconds)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run { self.onBurstEnded() }
        }
    }

    private func onBurstEnded() {
        guard !isFinished, let newest = history.keys.max() else { return }

        if history.count == sizeAtLastAsk {
            stalls += 1
            if stalls >= historyStallLimit {
                finishHistory(reason: "não há leituras além de #\(newest)")
                return
            }
        } else {
            stalls = 0
        }

        sizeAtLastAsk = history.count
        askAttempt = 0
        askFor(newest + 1)
    }

    private func interpretReply(_ bytes: [UInt8]) {
        lastPacketHex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")

        if GS1Protocol.isAuthRequest(bytes) {
            finishHistory(reason: "este sensor pediu o protocolo criptografado (newSI/GS3 ou variante não suportada)")
            return
        }

        guard GS1Protocol.isChecksumValid(bytes) else {
            status = "Frame recebido com checksum inválido; ignorado."
            return
        }

        guard let readings = GS1Protocol.parseGlucoseFrame(bytes), !readings.isEmpty else {
            // A non-glucose frame is treated like a complaint/other response. The retry task stays alive.
            return
        }

        retryTask?.cancel()
        readings.forEach { history[$0.index] = $0 }
        readingCount = history.count
        latestReading = history.values.max(by: { $0.index < $1.index })
        status = "Recebidas \(history.count) leituras; mais recente #\(latestReading?.index ?? 0)."
        scheduleBurstEnd()
    }

    private func finishHistory(reason: String) {
        guard !isFinished else { return }
        isFinished = true
        retryTask?.cancel()
        burstTask?.cancel()
        status = "Coleta encerrada: \(reason)."
    }
}

extension GS1BluetoothManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn: bluetoothState = "Ligado"
            case .poweredOff: bluetoothState = "Desligado"
            case .unauthorized: bluetoothState = "Sem permissão"
            case .unsupported: bluetoothState = "Não suportado"
            case .resetting: bluetoothState = "Reiniciando"
            case .unknown: bluetoothState = "Desconhecido"
            @unknown default: bluetoothState = "Outro"
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String : Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            guard self.isScanning, self.advertisementHasGS1Service(advertisementData) else { return }

            self.central.stopScan()
            self.isScanning = false
            self.peripheral = peripheral
            self.peripheralName = peripheral.name ?? "GS1 sem nome"
            self.peripheralIdentifier = peripheral.identifier.uuidString
            self.status = "GS1 encontrado (RSSI \(RSSI) dBm). Conectando…"
            peripheral.delegate = self
            self.central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.isConnected = true
            self.status = "Conectado. Descobrindo FF30…"
            peripheral.discoverServices([Self.dataService])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            self.isConnected = false
            self.status = "Falha ao conectar: \(error?.localizedDescription ?? "sem detalhe")"
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            self.isConnected = false
            self.status = "Desconectado\(error.map { ": \($0.localizedDescription)" } ?? ".")"
        }
    }
}

extension GS1BluetoothManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                self.status = "Erro descobrindo serviços: \(error.localizedDescription)"
                return
            }
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.dataService }) else {
                self.status = "Conectou, mas o serviço FF30 não apareceu."
                return
            }
            self.status = "FF30 encontrado. Descobrindo FF31/FF32…"
            peripheral.discoverCharacteristics(
                [Self.notifyCharacteristicUUID, Self.writeCharacteristicUUID],
                for: service
            )
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                self.status = "Erro descobrindo characteristics: \(error.localizedDescription)"
                return
            }

            for characteristic in service.characteristics ?? [] {
                if characteristic.uuid == Self.notifyCharacteristicUUID {
                    self.notifyCharacteristic = characteristic
                } else if characteristic.uuid == Self.writeCharacteristicUUID {
                    self.writeCharacteristic = characteristic
                }
            }
            self.subscribeAndStartIfReady()
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                self.status = "Falha ao habilitar FF31: \(error.localizedDescription)"
                return
            }
            guard characteristic.uuid == Self.notifyCharacteristicUUID,
                  characteristic.isNotifying else { return }
            self.status = "FF31 ativo. Enviando primeiro pedido em FF32…"
            self.askFor(self.nextIndex)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor in
            self.status = "O GS1 rejeitou a escrita em FF32: \(error.localizedDescription)"
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                self.status = "Erro recebendo FF31: \(error.localizedDescription)"
                return
            }
            guard characteristic.uuid == Self.notifyCharacteristicUUID,
                  let data = characteristic.value else { return }
            self.interpretReply([UInt8](data))
        }
    }
}
