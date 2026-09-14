import LibrasCore
import SwiftUI

struct TranslationScreen: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false
    @State private var confirmClearCache = false

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                SliderRow(title: "Normal", value: $model.settings.policy.baseSpeed, range: 0.5...3, step: 0.1, format: "%.1f×")
                SliderRow(title: "Máxima", value: $model.settings.policy.maxSpeed, range: max(1, model.settings.policy.baseSpeed)...4, step: 0.1, format: "%.1f×")
                if model.settings.policy.maxSpeed > 3 {
                    Label("Acima de 3× o avatar fica difícil de acompanhar. Confirme com quem usa Libras.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                SliderRow(title: "Acelerar após", value: $model.settings.policy.speedUpAfter, range: 1...20, step: 1, format: "%.0f s")
                SliderRow(title: "Descartar após", value: $model.settings.policy.dropAfter, range: max(5, model.settings.policy.speedUpAfter + 1)...60, step: 1, format: "%.0f s")
            } header: {
                Text("Velocidade do avatar")
            } footer: {
                Text("Sinalizar leva mais tempo que falar. Com atraso, o avatar acelera até a velocidade máxima; passando do limite, frases antigas são descartadas.")
            }

            Section {
                Toggle("Juntar frases da fila num envio só", isOn: $model.settings.policy.mergePhrases)
                if model.settings.policy.mergePhrases {
                    SliderRow(title: "Máximo por envio", value: $model.settings.policy.maxBatchSeconds, range: 4...30, step: 1, format: "%.0f s")
                }
                Toggle("Enxugar a glosa quando atrasado", isOn: $model.settings.policy.compactWhenBehind)
                Toggle("Descartar repetições primeiro", isOn: $model.settings.policy.dropRepeats)
            } header: {
                Text("Fila")
            } footer: {
                Text("Cada envio ao avatar tem cerca de 2 s de transição; juntar frases elimina essas pausas.")
            }

            Section("Glosa") {
                Toggle("Remover pausas de pontuação", isOn: $model.settings.removePauses)
                Picker("Palavras sem sinal", selection: $model.settings.unknownWords) {
                    Text("Soletrar").tag(GlossOptimizer.UnknownWordPolicy.spell)
                    Text("Soletrar só as curtas").tag(GlossOptimizer.UnknownWordPolicy.spellShort)
                    Text("Pular").tag(GlossOptimizer.UnknownWordPolicy.skip)
                }
                Toggle("Guardar sinais no cache local", isOn: $model.settings.useSignCache)
                Toggle("Consultar o dicionário antes de sinalizar", isOn: $model.settings.prefetchSigns)
                    .disabled(!model.settings.useSignCache)
            }

            Section {
                SliderRow(title: "Silêncio para confirmar", value: $model.settings.pauseCommitSeconds, range: 0...2, step: 0.1, format: "%.1f s")
                Toggle("Confirmar orações longas na vírgula", isOn: $model.settings.commitOnComma)
                LabeledContent("Palavras por trecho") {
                    Stepper(value: $model.settings.maxWords, in: 6...30) {
                        Text("\(model.settings.maxWords)").monospacedDigit()
                    }
                }
            } header: {
                Text("Reconhecimento de fala")
            } footer: {
                Text("O trecho segue para tradução numa pausa real (silêncio no áudio) ou quando as palavras param de mudar. Palavras incompletas nunca são enviadas.")
            }

            Section {
                LabeledContent("Glosas em cache", value: "\(model.glossCacheCount)")
                LabeledContent("Sinais", value: "\(model.signStats.hits) do cache · \(model.signStats.downloads) baixados · \(model.signStats.notFound) inexistentes")
                Button("Limpar cache de sinais…", role: .destructive) { confirmClearCache = true }
            } header: {
                Text("Dicionário")
            }

            Section {
                Button("Restaurar padrões…") { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Restaurar os ajustes de tradução?", isPresented: $confirmReset) {
            Button("Restaurar padrões", role: .destructive) { model.restoreTranslationDefaults() }
        } message: {
            Text("Velocidade, fila, glosa e reconhecimento voltam aos valores recomendados.")
        }
        .confirmationDialog("Limpar o cache de sinais?", isPresented: $confirmClearCache) {
            Button("Limpar", role: .destructive) { model.clearSignCache() }
        } message: {
            Text("Os sinais serão baixados de novo conforme aparecerem.")
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step)
                    .frame(minWidth: 110)
                Text(String(format: format, value))
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }
}
