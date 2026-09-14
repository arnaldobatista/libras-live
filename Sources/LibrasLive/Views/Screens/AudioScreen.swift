import AudioCapture
import SwiftUI

struct AudioScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            if let warning = model.captureWarning {
                Section {
                    Callout(
                        kind: .warning,
                        message: warning,
                        actionTitle: model.microphoneAuthorized ? nil : "Permitir microfone",
                        action: model.microphoneAuthorized ? nil : { model.requestMicrophoneAccess() }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                Picker("Dispositivo", selection: $model.settings.deviceUID) {
                    ForEach(model.devices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                    if model.settings.deviceUID != nil, model.selectedDevice == nil {
                        Text("Dispositivo desconectado").tag(model.settings.deviceUID)
                    }
                }
                if let device = model.selectedDevice {
                    LabeledContent("Formato", value: "\(device.inputChannels) \(device.inputChannels == 1 ? "canal" : "canais") · \(Int(device.sampleRate / 1000)) kHz")
                }
            } header: {
                HStack {
                    Text("Fonte de áudio")
                    Spacer()
                    Button {
                        model.refreshDevices()
                    } label: {
                        Label("Atualizar", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .help("Atualizar lista de dispositivos")
                }
            }

            if let device = model.selectedDevice {
                Section {
                    ChannelGrid(device: device, selected: Set(model.settings.channels), peaks: model.channelPeaks) { index in
                        model.toggleChannel(index)
                    }
                    .padding(.vertical, 4)

                    Toggle("Mostrar nível de cada canal", isOn: $model.isMonitoring)
                } header: {
                    Text("Canais")
                } footer: {
                    Text(channelFooter(device))
                }
            }

            Section {
                LabeledContent("Ganho") {
                    HStack {
                        Slider(value: $model.settings.gainDB, in: -12...24, step: 1)
                            .frame(minWidth: 110)
                        Text(String(format: "%+.0f dB", model.settings.gainDB))
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                LabeledContent("Nível") {
                    LevelMeter(level: model.level, active: model.isCapturing)
                        .frame(minWidth: 140)
                }
                LabeledContent("Detector de voz") {
                    VoiceIndicator(voiceDetected: model.voiceDetected, active: model.isListening)
                }
            } header: {
                Text("Nível")
            } footer: {
                Text("Ajuste o ganho para o nível ficar entre -30 e -10 dB quando alguém fala. Mande para o Mac um canal só de voz, sem música nem retorno.")
            }
        }
        .formStyle(.grouped)
    }

    private func channelFooter(_ device: AudioDevice) -> String {
        let valid = model.settings.channels.filter { $0 < device.inputChannels }
        guard !valid.isEmpty else { return "Selecione pelo menos um canal." }
        let list = valid.map { String($0 + 1) }.joined(separator: " + ")
        let prefix = valid.count == 1 ? "Canal \(list)." : "Canais \(list), somados em mono."
        return prefix + " Clique nos números para escolher; ligue o nível por canal para achar onde está a voz."
    }
}
