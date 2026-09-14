import SwiftUI

/// Boas-vindas guiadas no primeiro uso: permissão, fonte de áudio e OBS.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    let onFinish: () -> Void

    @State private var step = (ProcessInfo.processInfo.environment["LIBRAS_ONBOARDING_STEP"].flatMap(Int.init) ?? 1) - 1
    private let steps = 4

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: WelcomeStep()
                case 1: MicrophoneStep()
                case 2: AudioStep()
                default: OBSStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 36)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .id(step)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<steps, id: \.self) { index in
                        Capsule()
                            .fill(index == step ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary))
                            .frame(width: index == step ? 18 : 7, height: 7)
                    }
                }
                .animation(.snappy, value: step)
                .accessibilityLabel("Passo \(step + 1) de \(steps)")

                Spacer()

                if step > 0 {
                    Button("Voltar") { withAnimation(.snappy) { step -= 1 } }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                }
                Button(step == steps - 1 ? "Começar a usar" : "Continuar") {
                    if step == steps - 1 {
                        onFinish()
                    } else {
                        withAnimation(.snappy) { step += 1 }
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(24)
        }
        .frame(width: 600, height: 520)
    }
}

private struct StepHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.tint)
                .frame(height: 52)
            Text(title)
                .font(.title.weight(.semibold))
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 14) {
                BrandIcon(size: 96)
                Text("Boas-vindas ao Libras Live")
                    .font(.largeTitle.weight(.semibold))
                Text("Um avatar que traduz a fala da sua transmissão para Libras, direto no OBS.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 16) {
                Feature(symbol: "waveform", title: "Ouve o canal da mesa", text: "Escolha o dispositivo e o canal com a voz.")
                Feature(symbol: "hand.wave", title: "Traduz e sinaliza ao vivo", text: "A fala vira glosa e o avatar sinaliza em segundos.")
                Feature(symbol: "rectangle.on.rectangle", title: "Entra no OBS com fundo transparente", text: "É só adicionar uma fonte de navegador.")
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
    }
}

private struct Feature: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MicrophoneStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 28) {
            StepHeader(
                symbol: "mic.badge.plus",
                title: "Acesso ao áudio",
                subtitle: "O Libras Live precisa ouvir o canal escolhido. O reconhecimento de fala acontece no próprio Mac."
            )
            if model.microphoneAuthorized {
                Label("Acesso permitido", systemImage: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            } else {
                Button("Permitir acesso ao microfone") { model.requestMicrophoneAccess() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.extraLarge)
                Text("Se negou antes, libere em Ajustes do Sistema › Privacidade e Segurança › Microfone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AudioStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 24) {
            StepHeader(
                symbol: "waveform",
                title: "De onde vem a voz?",
                subtitle: "Escolha a mesa ou o microfone. Dá para ajustar os canais depois, em Áudio."
            )
            VStack(spacing: 14) {
                Picker("Dispositivo", selection: $model.settings.deviceUID) {
                    ForEach(model.devices) { device in
                        Text("\(device.name) (\(device.inputChannels) \(device.inputChannels == 1 ? "canal" : "canais"))").tag(Optional(device.uid))
                    }
                }
                .frame(maxWidth: 420)

                if let device = model.selectedDevice, device.inputChannels > 1 {
                    ChannelGrid(device: device, selected: Set(model.settings.channels), peaks: model.channelPeaks) { index in
                        model.toggleChannel(index)
                    }
                    .frame(maxWidth: 420)
                }
                LevelMeter(level: model.level, active: model.isCapturing)
                    .frame(maxWidth: 420)
            }
        }
        .onAppear { model.isMonitoring = true }
        .onDisappear { model.isMonitoring = false }
    }
}

private struct OBSStep: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(
                symbol: "rectangle.on.rectangle",
                title: "Coloque o avatar no OBS",
                subtitle: "Em Fontes, adicione um Navegador com esta URL, em 540 × 960. O fundo já é transparente."
            )
            HStack(spacing: 10) {
                Text(model.overlayURL.absoluteString)
                    .font(.system(.title3, design: .monospaced))
                    .textSelection(.enabled)
                Button {
                    model.copyOverlayURL()
                    withAnimation { copied = true }
                } label: {
                    Label(copied ? "Copiado" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glassProminent)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.fill.quinary, in: .capsule)

            let visible = model.overlayReady - model.overlayHidden
            Label(visible > 0 ? "OBS conectado" : "Aguardando o OBS…", systemImage: visible > 0 ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(visible > 0 ? .green : .secondary)
        }
    }
}
