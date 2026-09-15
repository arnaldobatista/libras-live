import LibrasCore
import LocalAI
import SwiftUI

/// IA local: liga a reescrita, escolhe modo e modelo, testa e gerencia os modelos do motor embutido.
struct AIScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showSearch = false
    @State private var testText = "passaremos muito mais tempo explicando e interpretando e expandindo os detalhes de cada eta."
    @State private var modelToDelete: InstalledModel?

    var body: some View {
        @Bindable var model = model
        let ai = model.localAI
        let hasModel = model.settings.rewrite.model.map { ai.isInstalled($0) } == true

        Form {
            if let error = ai.lastError {
                Section {
                    Callout(kind: .warning, message: error, actionTitle: "Tentar de novo", action: { ai.restartEngine() })
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                Toggle(isOn: $model.settings.rewrite.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reescrever as frases antes de traduzir")
                        Text("Roda neste Mac, sem mandar a fala para a internet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!hasModel && !model.settings.rewrite.enabled)

                RewriteModePicker(selection: $model.settings.rewrite.mode)

                Picker("Modelo", selection: $model.settings.rewrite.model) {
                    if ai.installed.isEmpty {
                        // Enquanto o motor sobe a lista ainda está vazia: mostra o modelo escolhido.
                        if let current = model.settings.rewrite.model {
                            Text(current).tag(Optional(current))
                        } else {
                            Text("Nenhum modelo instalado").tag(String?.none)
                        }
                    }
                    ForEach(ai.installed) { installed in
                        Text(installed.name).tag(Optional(installed.name))
                    }
                    if let current = model.settings.rewrite.model, !ai.installed.isEmpty, !ai.isInstalled(current) {
                        Text("\(current) (não instalado)").tag(Optional(current))
                    }
                }

                SliderRow(title: "Tempo máximo por frase", value: $model.settings.rewrite.timeout, range: 1...6, step: 0.5, format: "%.1f s")
                Toggle("Usar as frases anteriores como contexto", isOn: $model.settings.rewrite.useContext)
            } header: {
                Text("Reescrita com IA")
            } footer: {
                Text("A IA reescreve cada trecho antes da tradução em 1 a 2 s. Se passar do tempo máximo (trechos com mais de 20 palavras ganham mais tempo) ou a resposta parecer inventada, vai o texto original.")
            }

            GroupingSection()

            Section {
                TextField("Frase para testar", text: $testText, axis: .vertical)
                    .lineLimit(2...5)
                HStack {
                    if !hasModel {
                        Text("Baixe um modelo abaixo para testar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Testar os três modos", systemImage: "play.fill") {
                        if let name = model.settings.rewrite.model {
                            ai.runTests(testText, model: name, timeout: model.settings.rewrite.timeout)
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!hasModel || testText.trimmingCharacters(in: .whitespaces).isEmpty || ai.tests.contains(where: \.isRunning))
                }
                ForEach(ai.tests) { run in
                    RewriteTestRow(run: run)
                }
            } header: {
                Text("Testar")
            } footer: {
                if !ai.tests.isEmpty {
                    Text("O primeiro teste inclui carregar o modelo na memória. Na transmissão ele fica carregado.")
                }
            }

            Section {
                ForEach(ModelCatalog.recommendations) { recommendation in
                    RecommendationRow(recommendation: recommendation)
                }
                if let errors = downloadErrorsText(ai) {
                    Callout(kind: .error, message: errors, onDismiss: { ai.downloadErrors.keys.forEach(ai.dismissDownloadError) })
                }
            } header: {
                HStack {
                    Text("Recomendados para o seu Mac")
                    Spacer()
                    Text(ai.machine.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Medidos num MacBook Pro M1 Pro 16 GB reescrevendo frases reais de transmissões. Com o avatar sinalizando ao mesmo tempo, conte com cerca de 50% a mais. Modelos de 1 B ou menos erram e inventam; os de 8 B ou mais passam de 3 s por frase.")
            }

            Section {
                if ai.installed.isEmpty {
                    Text(ai.engineStatus.isRunning ? "Nenhum modelo instalado ainda." : "Os modelos aparecem quando o motor iniciar.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ai.installed) { installed in
                        InstalledModelRow(installed: installed) { modelToDelete = installed }
                    }
                }
                ForEach(ai.downloads.keys.sorted().filter { name in !ModelCatalog.recommendations.contains { $0.name == name } }, id: \.self) { name in
                    if let download = ai.downloads[name] {
                        LabeledContent(name) {
                            ModelDownloadProgress(download: download) { ai.cancelDownload(name) }
                        }
                    }
                }
                Button("Buscar outros modelos…", systemImage: "magnifyingglass") { showSearch = true }
            } header: {
                HStack {
                    Text("Modelos instalados")
                    Spacer()
                    if ai.modelsFolderBytes > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: ai.modelsFolderBytes, countStyle: .file)) em disco")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                LabeledContent("Ollama") {
                    EngineStatusLabel(status: ai.engineStatus)
                }
                HStack {
                    Button("Mostrar pasta dos modelos", systemImage: "folder") { ai.revealModelsFolder() }
                    Button("Ver log", systemImage: "doc.text") { ai.openEngineLog() }
                    Spacer()
                    Button("Reiniciar", systemImage: "arrow.clockwise") { ai.restartEngine() }
                        .disabled(ai.engineStatus == .starting)
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Motor")
            } footer: {
                Text("O Ollama vem dentro do app e só atende o próprio Libras Live. Ele não usa os modelos nem a porta de um Ollama que você já tenha instalado.")
            }
        }
        .formStyle(.grouped)
        .task {
            // LIBRAS_AI_SEARCH=1 abre a busca, LIBRAS_AI_TEST=1 roda o teste e LIBRAS_AI_PULL=<modelo> baixa
            // um modelo (capturas de tela e testes de interface).
            let environment = ProcessInfo.processInfo.environment
            if environment["LIBRAS_AI_SEARCH"] == "1" { showSearch = true }
            await ai.ensureEngine()
            // Sem modelo escolhido: fica com o recomendado instalado (ou o primeiro que houver).
            if model.settings.rewrite.model == nil {
                let preferred = ModelCatalog.recommendations.first { ai.isInstalled($0.name) }?.name
                model.settings.rewrite.model = preferred ?? ai.installed.first?.name
            }
            if let name = environment["LIBRAS_AI_PULL"] { ai.download(name) }
            if environment["LIBRAS_AI_TEST"] == "1", let name = model.settings.rewrite.model {
                ai.runTests(testText, model: name, timeout: model.settings.rewrite.timeout)
            }
        }
        .sheet(isPresented: $showSearch) {
            ModelSearchSheet()
                .environment(model)
        }
        .confirmationDialog(
            "Excluir \(modelToDelete?.name ?? "modelo")?",
            isPresented: Binding(get: { modelToDelete != nil }, set: { if !$0 { modelToDelete = nil } }),
            presenting: modelToDelete
        ) { installed in
            Button("Excluir", role: .destructive) {
                Task {
                    await ai.delete(installed.name)
                    if model.settings.rewrite.model == installed.name {
                        model.settings.rewrite.model = ai.installed.first?.name
                        if ai.installed.isEmpty { model.settings.rewrite.enabled = false }
                    }
                }
            }
        } message: { installed in
            Text("Libera \(ByteCountFormatter.string(fromByteCount: installed.size, countStyle: .file)). Dá para baixar de novo depois.")
        }
    }

    private func downloadErrorsText(_ ai: LocalAIController) -> String? {
        guard !ai.downloadErrors.isEmpty else { return nil }
        return ai.downloadErrors.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }
}

/// Quanto da fala vai de uma vez para a IA: até o ponto final ou por número de palavras.
private struct GroupingSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let grouping = model.settings.rewrite.grouping

        Section {
            Picker("Enviar para a IA", selection: $model.settings.rewrite.grouping.mode) {
                Text("Até o ponto final").tag(RewriteGrouping.Mode.sentence)
                Text("Por palavras").tag(RewriteGrouping.Mode.words)
            }
            .pickerStyle(.segmented)

            switch grouping.mode {
            case .sentence:
                SliderRow(title: "Máximo de palavras", value: intBinding($model.settings.rewrite.grouping.words), range: 10...60, step: 2, format: "%.0f")
            case .words:
                SliderRow(title: "Palavras por trecho", value: intBinding($model.settings.rewrite.grouping.words), range: 6...40, step: 1, format: "%.0f")
                SliderRow(title: "Pode passar até", value: intBinding($model.settings.rewrite.grouping.extraWords), range: 0...20, step: 1, format: "+%.0f")
            }
            SliderRow(title: "Pausa na fala que fecha o trecho", value: $model.settings.rewrite.grouping.pauseSeconds, range: 1...5, step: 0.5, format: "%.1f s")

            LabeledContent("Espera até a IA receber") {
                Text("cerca de \(Int(estimatedWait(grouping).rounded())) s")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if !model.rewriteGathering.isEmpty {
                LabeledContent("Juntando agora") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(model.rewriteGathering)
                            .lineLimit(2)
                            .truncationMode(.head)
                            .multilineTextAlignment(.trailing)
                        Text("\(model.rewriteGathering.split(whereSeparator: \.isWhitespace).count) palavras")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("O que vai para a IA")
        } footer: {
            Text(footer(grouping))
        }
    }

    private func footer(_ grouping: RewriteGrouping) -> String {
        let common = " A pausa na fala fecha o trecho antes. Trechos maiores são revisados melhor, mas chegam mais tarde ao avatar."
        switch grouping.mode {
        case .sentence:
            return "A frase vai inteira quando o reconhecedor põe o ponto final; frases com menos de \(RewriteGrouping.minimumSentenceWords) palavras juntam com a seguinte. Sem ponto, corta numa vírgula perto do máximo (pode passar até \(grouping.sentenceSlack) palavras)." + common
        case .words:
            return "Junta \(grouping.words) palavras e espera um ponto final até \(grouping.limitWords). Sem ponto, corta na última vírgula até esse limite, ou no limite." + common
        }
    }

    /// Na fala corrida saem cerca de 2,2 palavras por segundo (medido nas lives); frases costumam ter uns 20 palavras.
    private func estimatedWait(_ grouping: RewriteGrouping) -> Double {
        let words: Double = switch grouping.mode {
        case .sentence: Double(min(grouping.words, 20))
        case .words: Double(grouping.words) + Double(grouping.extraWords) / 2
        }
        return words / 2.2
    }

    private func intBinding(_ binding: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(binding.wrappedValue) }, set: { binding.wrappedValue = Int($0.rounded()) })
    }
}

struct EngineStatusLabel: View {
    let status: LocalAIController.EngineStatus

    var body: some View {
        switch status {
        case .stopped:
            Label("Parado", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .starting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Iniciando…").foregroundStyle(.secondary)
            }
        case let .running(version, port):
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Pronto · versão \(version) · porta \(String(port))")
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }
}

/// Busca na biblioteca do Ollama e download de qualquer versão.
struct ModelSearchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var exactName = ""
    @State private var expanded: String?

    var body: some View {
        let ai = model.localAI

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Buscar modelos")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Nome ou família (ex.: qwen, gemma, llama)", text: $query)
                        .textFieldStyle(.plain)
                        .onSubmit { ai.search(query) }
                    if ai.isSearching {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.fill.quinary, in: .capsule)
                .onChange(of: query) { _, value in ai.search(value) }

                HStack(spacing: 6) {
                    Text("Sugestões:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(["qwen", "gemma", "llama", "granite", "phi", "mistral"], id: \.self) { suggestion in
                        Button(suggestion) { query = suggestion }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }

                if let error = ai.searchError {
                    Callout(kind: .warning, message: error)
                }
            }
            .padding(20)

            List {
                // Modelos só da nuvem não rodam no Mac.
                ForEach(ai.searchResults.filter { !$0.cloudOnly }) { result in
                    SearchResultRow(result: result, isExpanded: expanded == result.name) {
                        expanded = expanded == result.name ? nil : result.name
                        if expanded == result.name { ai.loadTags(for: result.name) }
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if ai.searchResults.isEmpty, !ai.isSearching {
                    ContentUnavailableView("Busque um modelo", systemImage: "magnifyingglass", description: Text("Os resultados vêm de ollama.com. Modelos pequenos (1 a 4 B) rodam rápido neste Mac."))
                }
            }

            Divider()
            HStack(spacing: 10) {
                TextField("Baixar pelo nome exato (ex.: qwen3.5:4b)", text: $exactName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(downloadExact)
                Button("Baixar", action: downloadExact)
                    .disabled(exactName.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer(minLength: 20)
                Button("Fechar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 520, idealHeight: 640)
        .onAppear {
            if ai.searchResults.isEmpty { ai.search("") }
        }
    }

    private func downloadExact() {
        let name = exactName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        model.localAI.download(name)
        exactName = ""
    }
}

private struct SearchResultRow: View {
    @Environment(AppModel.self) private var model
    let result: OllamaLibrary.Model
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        let ai = model.localAI

        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(result.name).font(.headline)
                            ForEach(result.capabilities, id: \.self) { Pill(text: $0) }
                            if result.cloudOnly { Pill(text: "só na nuvem") }
                        }
                        if !result.summary.isEmpty {
                            Text(result.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        HStack(spacing: 10) {
                            if !result.sizes.isEmpty { Text(result.sizes.joined(separator: " · ")) }
                            if !result.pulls.isEmpty { Label(result.pulls, systemImage: "arrow.down.circle") }
                            if !result.updated.isEmpty { Text(result.updated) }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(CompactLabelStyle())
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(result.cloudOnly)

            if isExpanded {
                if ai.loadingTags.contains(result.name) {
                    ProgressView().controlSize(.small).padding(.leading, 22)
                } else {
                    let tags = (ai.tagsByModel[result.name] ?? []).filter(\.runsHere)
                    if tags.isEmpty {
                        Text("Nenhuma versão que rode neste Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 22)
                    }
                    ForEach(tags) { tag in
                        TagRow(tag: tag)
                            .padding(.leading, 22)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct TagRow: View {
    @Environment(AppModel.self) private var model
    let tag: OllamaLibrary.Tag

    var body: some View {
        let ai = model.localAI
        let tooBig = tag.bytes.map { Double($0) / 1e9 > Double(ai.machine.memoryGB) * 0.5 } ?? false

        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tag.name)
                    .font(.system(.callout, design: .monospaced))
                Text([tag.size, tag.context.isEmpty ? nil : "\(tag.context) de contexto", tag.inputs.isEmpty ? nil : tag.inputs].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(tooBig ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            Spacer()
            if let download = ai.downloads[tag.name] {
                ModelDownloadProgress(download: download) { ai.cancelDownload(tag.name) }
            } else if ai.isInstalled(tag.name) {
                Label("Instalado", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Button("Baixar") { ai.download(tag.name) }
                    .controlSize(.small)
                    .help(tooBig ? "Grande para este Mac: pode ficar lento com o OBS aberto." : "Baixar \(tag.size)")
            }
        }
    }
}
