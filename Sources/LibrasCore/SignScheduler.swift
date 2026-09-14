import Foundation

/// Regras para impedir que o avatar acumule atraso.
public struct BacklogPolicy: Sendable, Equatable, Codable {
    /// Velocidade normal do avatar.
    public var baseSpeed: Double
    /// Velocidade máxima quando o atraso é grande.
    public var maxSpeed: Double
    /// A partir desse atraso (s) o avatar começa a acelerar.
    public var speedUpAfter: TimeInterval
    /// A partir desse atraso (s) frases antigas são descartadas.
    public var dropAfter: TimeInterval
    /// Estimativa de segundos por palavra (velocidade 1) para frases ainda sem glosa.
    public var secondsPerWord: TimeInterval
    /// Junta as frases prontas da fila num único envio (evita ~2 s de transição por frase).
    public var mergePhrases: Bool
    /// Duração máxima estimada de um envio com frases juntas.
    public var maxBatchSeconds: TimeInterval
    /// Com atraso, pula palavras sem sinal e muletas antes de descartar frases.
    public var compactWhenBehind: Bool
    /// Com atraso, descarta primeiro frases que repetem o que acabou de ser sinalizado.
    public var dropRepeats: Bool

    public init(
        baseSpeed: Double = 1.0,
        maxSpeed: Double = 2.0,
        speedUpAfter: TimeInterval = 5,
        dropAfter: TimeInterval = 15,
        secondsPerWord: TimeInterval = 0.8,
        mergePhrases: Bool = true,
        maxBatchSeconds: TimeInterval = 20,
        compactWhenBehind: Bool = true,
        dropRepeats: Bool = true
    ) {
        self.baseSpeed = baseSpeed
        self.maxSpeed = max(baseSpeed, maxSpeed)
        self.speedUpAfter = speedUpAfter
        self.dropAfter = max(speedUpAfter + 1, dropAfter)
        self.secondsPerWord = secondsPerWord
        self.mergePhrases = mergePhrases
        self.maxBatchSeconds = maxBatchSeconds
        self.compactWhenBehind = compactWhenBehind
        self.dropRepeats = dropRepeats
    }

    // Decodificação tolerante: preferências antigas continuam valendo.
    public init(from decoder: Decoder) throws {
        let d = BacklogPolicy()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            baseSpeed: try c.decodeIfPresent(Double.self, forKey: .baseSpeed) ?? d.baseSpeed,
            maxSpeed: try c.decodeIfPresent(Double.self, forKey: .maxSpeed) ?? d.maxSpeed,
            speedUpAfter: try c.decodeIfPresent(Double.self, forKey: .speedUpAfter) ?? d.speedUpAfter,
            dropAfter: try c.decodeIfPresent(Double.self, forKey: .dropAfter) ?? d.dropAfter,
            secondsPerWord: try c.decodeIfPresent(Double.self, forKey: .secondsPerWord) ?? d.secondsPerWord,
            mergePhrases: try c.decodeIfPresent(Bool.self, forKey: .mergePhrases) ?? d.mergePhrases,
            maxBatchSeconds: try c.decodeIfPresent(Double.self, forKey: .maxBatchSeconds) ?? d.maxBatchSeconds,
            compactWhenBehind: try c.decodeIfPresent(Bool.self, forKey: .compactWhenBehind) ?? d.compactWhenBehind,
            dropRepeats: try c.decodeIfPresent(Bool.self, forKey: .dropRepeats) ?? d.dropRepeats
        )
    }

    /// Interpola linearmente de `baseSpeed` (em `speedUpAfter`) até `maxSpeed` (em `dropAfter`).
    public func speed(forLag lag: TimeInterval) -> Double {
        guard lag > speedUpAfter else { return baseSpeed }
        guard lag < dropAfter else { return maxSpeed }
        let t = (lag - speedUpAfter) / (dropAfter - speedUpAfter)
        return baseSpeed + (maxSpeed - baseSpeed) * t
    }
}

public struct SignItem: Identifiable, Sendable, Equatable {
    public let id: Int
    public let text: String
    public let createdAt: Date
    /// Tokens da glosa original (nil enquanto traduz).
    public var tokens: [String]?
    /// Disponibilidade de sinais no dicionário (`true` existe, `false` não existe).
    public var availability: [String: Bool] = [:]
    public var usedFallback = false

    public var gloss: String? { tokens?.joined(separator: " ") }
    public var isReady: Bool { tokens != nil }
    public var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
}

public enum DropReason: String, Sendable, Equatable {
    /// Ficou velha demais na fila.
    case stale = "atrasada"
    /// Repete o que foi sinalizado há pouco (com a fila atrasada).
    case repeated = "repetida"
    /// A glosa ficou vazia depois de otimizada (ex.: só pontuação).
    case empty = "vazia"
}

public struct DropRecord: Sendable, Equatable {
    public let item: SignItem
    public let reason: DropReason
    public let age: TimeInterval
}

public struct BatchPart: Sendable, Equatable {
    public let item: SignItem
    public let optimization: GlossOptimizer.Result
}

public struct SignDispatch: Sendable, Equatable {
    /// Id enviado ao overlay (o do primeiro item do envio).
    public let id: Int
    public let parts: [BatchPart]
    public let gloss: String
    public let speed: Double
    public let lag: TimeInterval
    public let estimatedDuration: TimeInterval

    public var itemIDs: [Int] { parts.map(\.item.id) }
    public var text: String { parts.map(\.item.text).joined(separator: " ") }
}

public struct PlayingBatch: Sendable, Equatable {
    public let id: Int
    public let itemIDs: [Int]
    public let startedAt: Date
    public let deadline: Date
}

public struct SchedulerStep: Sendable, Equatable {
    public var dispatch: SignDispatch?
    public var dropped: [DropRecord] = []
}

public struct SchedulerSnapshot: Sendable, Equatable {
    public var queued: Int = 0
    public var lag: TimeInterval = 0
    public var speed: Double = 1
    public var dropped: Int = 0
    public var played: Int = 0
    public var playingID: Int?

    public init() {}

    public init(queued: Int, lag: TimeInterval, speed: Double, dropped: Int, played: Int, playingID: Int?) {
        self.queued = queued
        self.lag = lag
        self.speed = speed
        self.dropped = dropped
        self.played = played
        self.playingID = playingID
    }
}

/// Máquina de estados da fila de sinais (sem I/O, testável).
///
/// Mantém a ordem da fala, espera a glosa do item da frente, junta frases prontas num
/// único envio, otimiza a glosa conforme o atraso e descarta repetições e frases velhas.
public struct SignScheduler: Sendable {
    public var policy: BacklogPolicy
    public var glossOptions: GlossOptimizer.Options
    public var costs: SigningCosts

    public private(set) var queue: [SignItem] = []
    public private(set) var playing: PlayingBatch?
    public private(set) var droppedCount = 0
    public private(set) var playedCount = 0
    public private(set) var lastSpeed: Double

    private var recent: [(tokens: Set<String>, at: Date)] = []
    private var nextID = 1
    private let repeatWindow: TimeInterval = 60
    private let repeatSimilarity = 0.75

    public init(policy: BacklogPolicy = BacklogPolicy(), glossOptions: GlossOptimizer.Options = .init(), costs: SigningCosts = SigningCosts()) {
        self.policy = policy
        self.glossOptions = glossOptions
        self.costs = costs
        self.lastSpeed = policy.baseSpeed
    }

    // MARK: Entrada

    @discardableResult
    public mutating func enqueue(text: String, at now: Date = Date()) -> SignItem {
        let item = SignItem(id: nextID, text: text, createdAt: now)
        nextID += 1
        queue.append(item)
        return item
    }

    public mutating func setGloss(id: Int, tokens: [String], availability: [String: Bool] = [:], usedFallback: Bool = false) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].tokens = tokens
        queue[index].availability = availability
        queue[index].usedFallback = usedFallback
    }

    public mutating func setGloss(id: Int, gloss: String, usedFallback: Bool = false) {
        setGloss(id: id, tokens: gloss.split(separator: " ").map(String.init), usedFallback: usedFallback)
    }

    // MARK: Atraso

    /// Atraso efetivo: o maior entre a idade do item da frente e o tempo que o último item
    /// vai esperar enquanto os anteriores são sinalizados.
    public func lag(at now: Date = Date()) -> TimeInterval {
        guard let head = queue.first else { return 0 }
        let age = now.timeIntervalSince(head.createdAt)
        let backlog = queue.dropLast().reduce(0) { $0 + signingSeconds(of: $1, speed: policy.baseSpeed) }
        return max(age, backlog)
    }

    /// Segundos de sinalização do item, sem a transição fixa do envio.
    func signingSeconds(of item: SignItem, speed: Double) -> TimeInterval {
        guard let tokens = item.tokens else {
            return Double(item.wordCount) * policy.secondsPerWord / max(speed, 0.1)
        }
        let optimized = GlossOptimizer.optimize(tokens, availability: item.availability, options: glossOptions)
        return GlossOptimizer.estimatedDuration(optimized.tokens, availability: item.availability, speed: speed, costs: costs) - costs.overheadPerPlay
    }

    /// Opções de otimização para o atraso atual: quanto mais atrasado, mais enxuta a glosa.
    public func options(forLag lag: TimeInterval) -> GlossOptimizer.Options {
        var options = glossOptions
        guard policy.compactWhenBehind else { return options }
        if lag >= policy.speedUpAfter, options.unknownWords == .spell {
            options.unknownWords = .spellShort
        }
        if lag >= (policy.speedUpAfter + policy.dropAfter) / 2 {
            options.unknownWords = .skip
            options.removeFillers = true
        }
        return options
    }

    // MARK: Envio

    /// Decide o próximo envio. Não envia se estiver tocando, sem overlay pronto
    /// ou esperando a glosa do item da frente.
    public mutating func next(at now: Date = Date(), overlayReady: Bool) -> SchedulerStep {
        var step = SchedulerStep()
        guard playing == nil, overlayReady else { return step }

        step.dropped = dropStale(at: now)

        while let head = queue.first, head.isReady {
            let lag = self.lag(at: now)
            let speed = policy.speed(forLag: lag)
            let options = self.options(forLag: lag)

            var parts: [BatchPart] = []
            var tokens: [String] = []
            var estimate = costs.overheadPerPlay

            for item in queue {
                guard let itemTokens = item.tokens else { break }
                let result = GlossOptimizer.optimize(itemTokens, availability: item.availability, options: options)
                let seconds = GlossOptimizer.estimatedDuration(result.tokens, availability: item.availability, speed: speed, costs: costs) - costs.overheadPerPlay
                if !parts.isEmpty {
                    guard policy.mergePhrases, estimate + seconds <= policy.maxBatchSeconds else { break }
                }
                parts.append(BatchPart(item: item, optimization: result))
                var signs = result.tokens
                if let last = tokens.last, signs.first == last { signs.removeFirst() }
                tokens.append(contentsOf: signs)
                estimate += seconds
            }
            queue.removeFirst(parts.count)

            guard !tokens.isEmpty else {
                // Nada para sinalizar (ex.: só pontuação): não acorda o avatar.
                step.dropped += parts.map { DropRecord(item: $0.item, reason: .empty, age: now.timeIntervalSince($0.item.createdAt)) }
                continue
            }

            let id = parts[0].item.id
            playing = PlayingBatch(
                id: id,
                itemIDs: parts.map(\.item.id),
                startedAt: now,
                deadline: now.addingTimeInterval(estimate * 1.6 + 10)
            )
            playedCount += parts.count
            lastSpeed = speed
            remember(tokens, at: now)

            step.dispatch = SignDispatch(
                id: id,
                parts: parts,
                gloss: tokens.joined(separator: " "),
                speed: speed,
                lag: lag,
                estimatedDuration: estimate
            )
            return step
        }
        return step
    }

    /// Overlay avisou que terminou. Ignora ids que não são o envio atual.
    @discardableResult
    public mutating func markEnded(id: Int) -> PlayingBatch? {
        guard let playing, playing.id == id else { return nil }
        self.playing = nil
        return playing
    }

    /// Libera o player se o overlay não respondeu dentro do prazo.
    @discardableResult
    public mutating func expireIfNeeded(at now: Date = Date()) -> PlayingBatch? {
        guard let playing, now >= playing.deadline else { return nil }
        self.playing = nil
        return playing
    }

    /// Esquece o envio atual (ex.: overlay desconectou).
    @discardableResult
    public mutating func resetPlaying() -> PlayingBatch? {
        defer { playing = nil }
        return playing
    }

    /// Esvazia a fila e devolve os itens descartados.
    @discardableResult
    public mutating func clear() -> [SignItem] {
        let removed = queue
        droppedCount += queue.count
        queue.removeAll()
        playing = nil
        return removed
    }

    public func snapshot(at now: Date = Date()) -> SchedulerSnapshot {
        SchedulerSnapshot(
            queued: queue.count,
            lag: lag(at: now),
            speed: lastSpeed,
            dropped: droppedCount,
            played: playedCount,
            playingID: playing?.id
        )
    }

    // MARK: Descarte

    private mutating func dropStale(at now: Date) -> [DropRecord] {
        var drops: [DropRecord] = []

        func drop(at index: Int, _ reason: DropReason) {
            let item = queue.remove(at: index)
            drops.append(DropRecord(item: item, reason: reason, age: now.timeIntervalSince(item.createdAt)))
        }

        // Atrasado: primeiro saem as repetições (refrões), preservando a frase mais recente.
        if policy.dropRepeats, queue.count > 1, lag(at: now) >= policy.speedUpAfter {
            let window = repeatWindow
            recent.removeAll { now.timeIntervalSince($0.at) > window }
            var index = 0
            while index < queue.count - 1 {
                if let tokens = queue[index].tokens, isRepeat(tokens) {
                    drop(at: index, .repeated)
                } else {
                    index += 1
                }
            }
        }

        // Frases velhas demais; mantém sempre a mais recente, a menos que ela também esteja muito velha.
        while queue.count > 1, now.timeIntervalSince(queue[0].createdAt) > policy.dropAfter {
            drop(at: 0, .stale)
        }
        if let head = queue.first, now.timeIntervalSince(head.createdAt) > policy.dropAfter * 2 {
            drop(at: 0, .stale)
        }

        droppedCount += drops.count
        return drops
    }

    private mutating func remember(_ tokens: [String], at now: Date) {
        let window = repeatWindow
        recent.append((Self.contentSet(tokens), now))
        recent.removeAll { now.timeIntervalSince($0.at) > window }
    }

    private func isRepeat(_ tokens: [String]) -> Bool {
        let set = Self.contentSet(tokens)
        guard !set.isEmpty else { return false }
        return recent.contains { previous in
            let union = set.union(previous.tokens).count
            return union > 0 && Double(set.intersection(previous.tokens).count) / Double(union) >= repeatSimilarity
        }
    }

    private static func contentSet(_ tokens: [String]) -> Set<String> {
        Set(tokens.filter { !$0.hasPrefix("[") })
    }
}
