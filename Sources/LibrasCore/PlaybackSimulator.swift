import Foundation

/// Reproduz uma sessão (frases com horário e glosa) contra a fila de sinais, com o avatar
/// modelado pelos custos medidos. Serve para comparar configurações com dados de live real.
public struct PlaybackSimulator: Sendable {
    public struct Phrase: Sendable, Equatable {
        public var time: TimeInterval
        public var text: String
        public var tokens: [String]

        public init(time: TimeInterval, text: String, tokens: [String]) {
            self.time = time
            self.text = text
            self.tokens = tokens
        }
    }

    public struct Report: Sendable, Equatable {
        public var phrases = 0
        public var dispatches = 0
        public var played = 0
        public var dropped: [DropReason: Int] = [:]
        public var playingSeconds: TimeInterval = 0
        public var idleSeconds: TimeInterval = 0
        public var sessionSeconds: TimeInterval = 0
        public var speeds: [Double] = []
        public var lags: [TimeInterval] = []
        public var timeline: [String] = []

        public var droppedTotal: Int { dropped.filter { $0.key != .empty }.values.reduce(0, +) }
        public var averageSpeed: Double { speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count) }
        public var averageLag: TimeInterval { lags.isEmpty ? 0 : lags.reduce(0, +) / Double(lags.count) }
    }

    public var policy: BacklogPolicy
    public var glossOptions: GlossOptimizer.Options
    public var costs: SigningCosts
    /// Tempo entre a frase entrar na fila e a glosa ficar pronta (tradução + dicionário).
    public var readyDelay: TimeInterval

    public init(policy: BacklogPolicy, glossOptions: GlossOptimizer.Options, costs: SigningCosts = SigningCosts(), readyDelay: TimeInterval = 0.2) {
        self.policy = policy
        self.glossOptions = glossOptions
        self.costs = costs
        self.readyDelay = readyDelay
    }

    public func run(_ phrases: [Phrase], availability: [String: Bool]) -> Report {
        var report = Report()
        report.phrases = phrases.count
        guard let first = phrases.map(\.time).min() else { return report }

        let origin = Date(timeIntervalSince1970: 0)
        func date(_ t: TimeInterval) -> Date { origin.addingTimeInterval(t) }

        var scheduler = SignScheduler(policy: policy, glossOptions: glossOptions, costs: costs)
        let arrivals = phrases.sorted { $0.time < $1.time }
        var nextArrival = 0
        var pendingReady: [(at: TimeInterval, id: Int, tokens: [String])] = []
        var playingUntil: TimeInterval?
        var clock = first
        var lastEnd = first

        while nextArrival < arrivals.count || !pendingReady.isEmpty || !scheduler.queue.isEmpty || playingUntil != nil {
            // Próximo evento: chegada, glosa pronta ou fim do envio atual.
            var candidates: [TimeInterval] = []
            if nextArrival < arrivals.count { candidates.append(arrivals[nextArrival].time) }
            if let ready = pendingReady.map(\.at).min() { candidates.append(ready) }
            if let end = playingUntil { candidates.append(end) }
            // Fila parada esperando nada: avança até o próximo evento possível.
            guard let next = candidates.min() else { break }
            clock = max(clock, next)

            while nextArrival < arrivals.count, arrivals[nextArrival].time <= clock {
                let phrase = arrivals[nextArrival]
                let item = scheduler.enqueue(text: phrase.text, at: date(phrase.time))
                pendingReady.append((phrase.time + readyDelay, item.id, phrase.tokens))
                nextArrival += 1
            }

            for ready in pendingReady where ready.at <= clock {
                let names = ready.tokens + GlossOptimizer.lookupNames(for: ready.tokens, availability: availability)
                let known = availability.filter { names.contains($0.key) }
                scheduler.setGloss(id: ready.id, tokens: ready.tokens, availability: known)
            }
            pendingReady.removeAll { $0.at <= clock }

            if let end = playingUntil, end <= clock, let playing = scheduler.playing {
                scheduler.markEnded(id: playing.id)
                playingUntil = nil
                lastEnd = end
            }

            guard playingUntil == nil else { continue }
            let step = scheduler.next(at: date(clock), overlayReady: true)
            for drop in step.dropped {
                report.dropped[drop.reason, default: 0] += 1
                report.timeline.append(String(format: "%7.1f  DESCARTE (%@) %@", clock - first, drop.reason.rawValue, drop.item.text))
            }
            if let dispatch = step.dispatch {
                let knownAvailability = dispatch.parts.reduce(into: [String: Bool]()) { $0.merge($1.item.availability) { a, _ in a } }
                let duration = GlossOptimizer.estimatedDuration(
                    dispatch.gloss.split(separator: " ").map(String.init),
                    availability: knownAvailability,
                    speed: dispatch.speed,
                    costs: costs
                )
                report.idleSeconds += max(0, clock - lastEnd)
                report.playingSeconds += duration
                report.dispatches += 1
                report.played += dispatch.parts.count
                report.speeds.append(dispatch.speed)
                report.lags.append(dispatch.lag)
                report.timeline.append(String(format: "%7.1f  TOCA %d frase(s) %.2f× atraso %.1fs dura %.1fs: %@",
                                              clock - first, dispatch.parts.count, dispatch.speed, dispatch.lag, duration, dispatch.gloss))
                playingUntil = clock + duration
                lastEnd = clock + duration
            }
        }

        report.sessionSeconds = lastEnd - first
        return report
    }

    /// Lê linhas `HH:MM:SS<TAB>texto<TAB>glosa`.
    public static func parseTSV(_ contents: String) -> [Phrase] {
        var phrases: [Phrase] = []
        var lastSecond: TimeInterval = -1
        var sameSecondOffset: TimeInterval = 0

        for line in contents.split(separator: "\n") where !line.hasPrefix("#") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 3 else { continue }
            let clock = columns[0].split(separator: ":").compactMap { Double($0) }
            guard clock.count == 3 else { continue }
            let seconds = clock[0] * 3600 + clock[1] * 60 + clock[2]
            // Frases no mesmo segundo chegam em sequência.
            sameSecondOffset = seconds == lastSecond ? sameSecondOffset + 0.5 : 0
            lastSecond = seconds
            phrases.append(Phrase(
                time: seconds + sameSecondOffset,
                text: columns[1],
                tokens: columns[2].split(separator: " ").map(String.init)
            ))
        }
        return phrases
    }
}
