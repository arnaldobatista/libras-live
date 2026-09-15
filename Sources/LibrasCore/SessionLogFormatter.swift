import Foundation

/// Converte o log de sessão (JSON Lines) em texto legível com resumo.
///
/// Cada linha do log é um objeto com `t` (data ISO 8601), `ev` (tipo do evento) e campos do evento.
public enum SessionLogFormatter {
    public struct Summary: Sendable, Equatable {
        public var start: Date?
        public var end: Date?
        public var commits = 0
        public var enqueued = 0
        public var dispatched = 0
        public var dropped = 0
        public var fallbacks = 0
        public var speeds: [Double] = []
        public var lags: [Double] = []
        public var idleSeconds: Double = 0
        public var playingSeconds: Double = 0
        public var missingSigns: [String: Int] = [:]
        public var removedTokens: [String: Int] = [:]
        /// Trechos por origem (estável, pausa, final...).
        public var commitSources: [String: Int] = [:]
        public var commitWords: [Int] = []
        /// Espera de cada frase entre entrar na fila e começar o envio.
        public var queueWaits: [Double] = []
        public var dispatchSizes: [Int] = []
        /// Tempo até a frase ficar pronta (tradução + dicionário), em ms.
        public var readyTimes: [Double] = []
        /// Reescrita com IA: trechos enviados, quantos mudaram, motivos de ficar o original e tempos.
        public var rewrites = 0
        public var rewritesChanged = 0
        public var rewriteFallbacks: [String: Int] = [:]
        public var rewriteSeconds: [Double] = []
        /// Espera pelo fim da frase antes de a IA começar.
        public var rewriteWaits: [Double] = []
        /// Palavras em cada trecho enviado à IA.
        public var rewriteWords: [Int] = []

        public var dropRate: Double {
            let total = dispatched + dropped
            return total == 0 ? 0 : Double(dropped) / Double(total)
        }
    }

    public static func parse(_ jsonl: String) -> [[String: Any]] {
        jsonl.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    public static func summarize(_ events: [[String: Any]]) -> Summary {
        var summary = Summary()
        var playingSince: Date?
        var idleSince: Date?
        var listening = false
        var enqueuedAt: [Int: Date] = [:]

        for event in events {
            guard let type = event["ev"] as? String, let date = date(event["t"]) else { continue }
            summary.start = summary.start ?? date
            summary.end = date

            switch type {
            case "listen.start":
                listening = true
                if playingSince == nil { idleSince = date }
            case "listen.stop":
                listening = false
                if let since = idleSince { summary.idleSeconds += date.timeIntervalSince(since) }
                idleSince = nil
            case "commit":
                summary.commits += 1
                summary.commitSources[event["source"] as? String ?? "?", default: 0] += 1
                if let text = event["text"] as? String { summary.commitWords.append(text.split(separator: " ").count) }
            case "enqueue":
                summary.enqueued += 1
                if let id = event["id"] as? Int { enqueuedAt[id] = date }
            case "ready":
                if let ms = event["ms"] as? Double { summary.readyTimes.append(ms) }
            case "gloss":
                if (event["source"] as? String) == "fallback" { summary.fallbacks += 1 }
            case "optimize":
                for token in event["removed"] as? [String] ?? [] { summary.removedTokens[token, default: 0] += 1 }
            case "dispatch":
                let ids = event["ids"] as? [Int] ?? []
                summary.dispatched += max(ids.count, 1)
                summary.dispatchSizes.append(max(ids.count, 1))
                for id in ids {
                    if let enqueued = enqueuedAt[id] { summary.queueWaits.append(date.timeIntervalSince(enqueued)) }
                }
                if let speed = event["speed"] as? Double { summary.speeds.append(speed) }
                if let lag = event["lag"] as? Double { summary.lags.append(lag) }
                if let since = idleSince, listening { summary.idleSeconds += date.timeIntervalSince(since) }
                idleSince = nil
                playingSince = date
            case "ended":
                if let since = playingSince { summary.playingSeconds += date.timeIntervalSince(since) }
                playingSince = nil
                idleSince = listening ? date : nil
            case "drop":
                summary.dropped += 1
            case "sign.missing":
                if let name = event["name"] as? String { summary.missingSigns[name, default: 0] += 1 }
            case "rewrite":
                summary.rewrites += 1
                switch event["status"] as? String {
                case "rewritten": summary.rewritesChanged += 1
                case "fallback": summary.rewriteFallbacks[event["reason"] as? String ?? "?", default: 0] += 1
                default: break
                }
                if let seconds = event["seconds"] as? Double, event["status"] as? String != "fallback" || seconds > 0 {
                    summary.rewriteSeconds.append(seconds)
                }
                if let waited = event["waited"] as? Double { summary.rewriteWaits.append(waited) }
                if let original = event["original"] as? String {
                    summary.rewriteWords.append(event["words"] as? Int ?? original.split(separator: " ").count)
                }
            default:
                break
            }
        }
        return summary
    }

    /// Texto legível: resumo seguido da linha do tempo.
    public static func format(_ jsonl: String) -> String {
        let events = parse(jsonl)
        let summary = summarize(events)
        var lines: [String] = []

        lines.append("LIBRAS LIVE — LOG DE SESSÃO")
        if let start = summary.start, let end = summary.end {
            lines.append("Início: \(fullDate(start))   Fim: \(fullDate(end))   Duração: \(duration(end.timeIntervalSince(start)))")
        }
        lines.append("")
        lines.append("RESUMO")
        lines.append("  Trechos confirmados: \(summary.commits)   Na fila: \(summary.enqueued)")
        lines.append("  Sinalizados: \(summary.dispatched)   Descartados: \(summary.dropped) (\(percent(summary.dropRate)))   Sem tradução: \(summary.fallbacks)")
        if !summary.speeds.isEmpty {
            lines.append(String(format: "  Velocidade média: %.2f×   Atraso médio no envio: %.1f s   Atraso máximo: %.1f s",
                                average(summary.speeds), average(summary.lags), summary.lags.max() ?? 0))
        }
        if !summary.commitSources.isEmpty {
            let sources = summary.commitSources.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            lines.append(String(format: "  Trechos por origem: %@ · palavras por trecho: média %.1f", sources, average(summary.commitWords.map(Double.init))))
        }
        if !summary.queueWaits.isEmpty {
            let sorted = summary.queueWaits.sorted()
            lines.append(String(format: "  Espera na fila até sinalizar: média %.1f s · mediana %.1f s · 90%% até %.1f s",
                                average(sorted), sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]))
            lines.append(String(format: "  Envios: %d · frases por envio: média %.1f", summary.dispatchSizes.count, average(summary.dispatchSizes.map(Double.init))))
        }
        if !summary.readyTimes.isEmpty {
            lines.append(String(format: "  Frase pronta (tradução + dicionário): média %.0f ms · máximo %.0f ms", average(summary.readyTimes), summary.readyTimes.max() ?? 0))
        }
        if summary.rewrites > 0 {
            var line = String(format: "  IA (reescrita): %d trechos · %.1f palavras por trecho · mudou %d (%@) · tempo médio %.2f s · espera pelo fim da frase %.1f s",
                              summary.rewrites, average(summary.rewriteWords.map(Double.init)), summary.rewritesChanged,
                              percent(Double(summary.rewritesChanged) / Double(summary.rewrites)),
                              average(summary.rewriteSeconds), average(summary.rewriteWaits))
            if !summary.rewriteFallbacks.isEmpty {
                line += " · ficou o original: " + summary.rewriteFallbacks.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            }
            lines.append(line)
        }
        let active = summary.playingSeconds + summary.idleSeconds
        if active > 0 {
            lines.append(String(format: "  Avatar sinalizando: %@   Parado enquanto ouvia: %@ (%@)",
                                duration(summary.playingSeconds), duration(summary.idleSeconds),
                                percent(summary.idleSeconds / active)))
        }
        if !summary.missingSigns.isEmpty {
            let top = summary.missingSigns.sorted { $0.value > $1.value }.prefix(30)
            lines.append("  Sinais inexistentes: " + top.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))
        }
        if !summary.removedTokens.isEmpty {
            let top = summary.removedTokens.sorted { $0.value > $1.value }.prefix(20)
            lines.append("  Sinais removidos da glosa: " + top.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))
        }
        lines.append("")
        lines.append("LINHA DO TEMPO")

        for event in events {
            if let line = timelineLine(event) { lines.append(line) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Linha do tempo

    static func timelineLine(_ event: [String: Any]) -> String? {
        guard let type = event["ev"] as? String, let date = date(event["t"]) else { return nil }
        let time = clock(date)
        let id = (event["id"] as? Int).map { "#\($0)" } ?? ""

        func str(_ key: String) -> String { event[key] as? String ?? "" }
        func num(_ key: String, _ format: String = "%.1f") -> String {
            (event[key] as? Double).map { String(format: format, $0) } ?? "—"
        }

        switch type {
        case "session.start":
            return "\(time)  SESSÃO    início · \(str("device")) canais \(event["channels"] as? [Int] ?? []) · \(str("settings"))"
        case "listen.start":
            return "\(time)  OUVIR     começou"
        case "listen.stop":
            return "\(time)  OUVIR     parou"
        case "commit":
            return "\(time)  FALA      \(str("text"))  [\(str("source"))]"
        case "gloss":
            let source = str("source")
            let extra = source == "fallback" ? " ⚠ \(str("error"))" : ""
            return "\(time)  GLOSA \(pad(id)) \(str("gloss"))  (\(source), \(num("ms", "%.0f")) ms)\(extra)"
        case "optimize":
            let removed = (event["removed"] as? [String] ?? []).joined(separator: " ")
            let replaced = (event["replaced"] as? [String] ?? []).joined(separator: ", ")
            var detail = "→ \(str("gloss"))"
            if !removed.isEmpty { detail += "  − \(removed)" }
            if !replaced.isEmpty { detail += "  ↻ \(replaced)" }
            return "\(time)  AJUSTE\(pad(id)) \(detail)"
        case "dispatch":
            let ids = (event["ids"] as? [Int] ?? []).map { "#\($0)" }.joined(separator: "+")
            return "\(time)  TOCA  \(pad(ids)) \(num("speed", "%.2f"))× · atraso \(num("lag")) s · fila \(event["queued"] as? Int ?? 0) · \(str("gloss"))"
        case "ended":
            return "\(time)  FIM   \(pad(id)) \(str("reason")) (\(num("duration")) s)"
        case "drop":
            return "\(time)  DESCARTE\(pad(id)) idade \(num("age")) s · \(str("reason")) · \(str("text"))"
        case "clear":
            return "\(time)  FILA      limpa"
        case "sign.missing":
            return "\(time)  SINAL     inexistente: \(str("name"))"
        case "overlay":
            return "\(time)  OVERLAY   \(str("state"))"
        case "warning", "error":
            return "\(time)  AVISO     \(str("message"))"
        case "settings":
            return "\(time)  AJUSTES   \(str("settings"))"
        case "rewrite":
            let status = str("status")
            let label = status == "rewritten" ? "mudou" : (status == "unchanged" ? "igual" : "original: \(str("reason"))")
            let text = status == "rewritten" ? "  → \(str("text"))" : (event["rejected"] as? String).map { "  ✗ \($0)" } ?? ""
            return "\(time)  IA        \(str("mode")) · \(num("seconds", "%.2f")) s · \(label) · \(str("original"))\(text)"
        default:
            return nil
        }
    }

    // MARK: Utilidades

    private static let isoParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return isoParser.date(from: text)
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    private static func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? "\(total / 60) min \(total % 60) s" : "\(total) s"
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    private static func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private static func pad(_ text: String) -> String {
        text.isEmpty ? "    " : " \(text)".padding(toLength: max(5, text.count + 1), withPad: " ", startingAt: 0)
    }
}
