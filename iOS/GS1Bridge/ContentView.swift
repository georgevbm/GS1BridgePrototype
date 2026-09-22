import SwiftUI

struct ContentView: View {
    @StateObject private var bluetooth = GS1BluetoothManager()
    @State private var macAddress = ""
    @State private var startIndex = "1"

    var body: some View {
        NavigationStack {
            Form {
                Section("Configuração do sensor") {
                    TextField("MAC — AA:BB:CC:DD:EE:FF", text: $macAddress)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))

                    TextField("Índice inicial", text: $startIndex)
                        .keyboardType(.numberPad)

                    Button(bluetooth.isScanning ? "Escaneando…" : "Escanear e conectar") {
                        bluetooth.configuredMacAddress = macAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                        bluetooth.startIndex = Int(startIndex) ?? 1
                        bluetooth.startScan()
                    }
                    .disabled(bluetooth.isScanning)

                    Button("Parar / desconectar", role: .destructive) {
                        bluetooth.stop()
                    }
                }

                Section("Bluetooth") {
                    LabeledContent("Estado", value: bluetooth.bluetoothState)
                    LabeledContent("Conectado", value: bluetooth.isConnected ? "Sim" : "Não")
                    LabeledContent("Periférico", value: bluetooth.peripheralName)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("UUID do iOS").font(.caption).foregroundStyle(.secondary)
                        Text(bluetooth.peripheralIdentifier)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                Section("Coleta") {
                    Text(bluetooth.status)
                    LabeledContent("Leituras recebidas", value: "\(bluetooth.readingCount)")

                    if let reading = bluetooth.latestReading {
                        LabeledContent("Índice", value: "#\(reading.index)")
                        LabeledContent("Temperatura", value: String(format: "%.1f °C", reading.temperatureCelsius))
                        LabeledContent("Valor do sensor", value: String(format: "%.1f mmol/L", reading.sensorMmolPerLitre))
                        if let corrected = bluetooth.temperatureCorrectedMmol {
                            LabeledContent("Corrigido por temperatura", value: String(format: "%.2f mmol/L", corrected))
                        }
                        LabeledContent("Elétrico raw", value: "\(reading.electricalRaw)")
                        LabeledContent("Status raw", value: "\(reading.status)")
                    }
                }

                Section("Último frame") {
                    Text(bluetooth.lastPacketHex)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }

                Section("Importante") {
                    Text("Protótipo de engenharia reversa para diagnóstico. O valor exibido ainda não inclui a calibração final necessária para representar glicose clínica e não deve ser usado para decisões de tratamento ou dose de insulina.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("GS1 Debug")
        }
    }
}
