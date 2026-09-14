import SwiftUI

struct OBSScreen: View {
    @Environment(AppModel.self) private var model
    @State private var background: AppModel.OverlayBackground = .transparent
    @State private var debug = false
    @State private var copied = false
    @State private var portText = ""

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Text(customURL.absoluteString)
                            .font(.system(.title3, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            model.copy(customURL.absoluteString)
                            withAnimation { copied = true }
                            Task {
                                try? await Task.sleep(for: .seconds(1.6))
                                withAnimation { copied = false }
                            }
                        } label: {
                            Label(copied ? "Copiado" : "Copiar URL", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.glassProminent)
                        .help("Copiar a URL para colar no OBS (⌥⌘C)")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        StepRow(number: 1, text: "No OBS, em Fontes, clique em + e escolha Navegador.")
                        StepRow(number: 2, text: "Cole a URL e use largura 540 e altura 960 (ou 720 × 720).")
                        StepRow(number: 3, text: "Deixe desmarcado \"Desligar fonte quando não visível\" para o avatar não recarregar ao trocar de cena.")
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("Conectar ao OBS")
            } footer: {
                Text("O fundo já é transparente: o avatar aparece direto sobre a sua cena.")
            }

            Section("Status") {
                let visible = model.overlayReady - model.overlayHidden
                LabeledContent("Overlays conectados") {
                    HStack(spacing: 6) {
                        Image(systemName: visible > 0 ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(visible > 0 ? .green : .secondary)
                        Text(visible > 0 ? "\(visible) visível\(visible > 1 ? "is" : "")" : "Nenhum")
                        if model.overlayHidden > 0 {
                            Text("· \(model.overlayHidden) oculto\(model.overlayHidden > 1 ? "s" : "")")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Servidor local") {
                    HStack(spacing: 6) {
                        Circle().fill(model.serverRunning ? Color.green : Color.red).frame(width: 8, height: 8)
                        Text(model.serverRunning ? "Ativo na porta \(String(model.port))" : "Parado")
                    }
                }
            }

            Section {
                Picker("Fundo", selection: $background) {
                    ForEach(AppModel.OverlayBackground.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Toggle("Painel de diagnóstico", isOn: $debug)
                Button("Abrir no navegador", systemImage: "safari") {
                    NSWorkspace.shared.open(customURL)
                }
            } header: {
                Text("Variações da URL")
            } footer: {
                Text("Chroma key só é necessário se a sua versão do OBS não aceitar transparência. O painel de diagnóstico mostra conexão, fala e glosa sobre o avatar.")
            }

            Section {
                LabeledContent("Porta") {
                    HStack {
                        TextField("Porta", text: $portText, prompt: Text(verbatim: "8765"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .onSubmit(applyPort)
                        Button("Aplicar", action: applyPort)
                            .disabled(Int(portText) == model.settings.port)
                    }
                }
            } header: {
                Text("Servidor")
            } footer: {
                Text("Mude a porta só se outro programa já usa a 8765. Depois, atualize a URL no OBS.")
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = String(model.settings.port) }
    }

    private var customURL: URL {
        model.overlayURL(background: background, debug: debug)
    }

    private func applyPort() {
        guard let port = Int(portText), (1024...65535).contains(port) else {
            portText = String(model.settings.port)
            return
        }
        model.settings.port = port
    }
}

private struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(.tint))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
