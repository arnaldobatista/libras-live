import Darwin
import Foundation

/// Motor Ollama que vem dentro do app: um `ollama serve` só do Libras Live, numa porta própria,
/// com os modelos na pasta do app. Fecha junto com o app.
public actor OllamaEngine {
    public struct Configuration: Sendable {
        /// Executável `ollama` (no app: Contents/Resources/ollama/ollama).
        public var binary: URL
        /// Onde ficam os modelos (OLLAMA_MODELS).
        public var modelsDirectory: URL
        /// HOME do processo: chave e arquivos do Ollama ficam aqui, fora da pasta do usuário.
        public var homeDirectory: URL
        public var logFile: URL
        public var pidFile: URL
        public var preferredPort: Int

        public init(binary: URL, supportDirectory: URL, preferredPort: Int = 11439) {
            self.binary = binary
            modelsDirectory = supportDirectory.appendingPathComponent("models", isDirectory: true)
            homeDirectory = supportDirectory.appendingPathComponent("home", isDirectory: true)
            logFile = supportDirectory.appendingPathComponent("motor.log")
            pidFile = supportDirectory.appendingPathComponent("motor.pid")
            self.preferredPort = preferredPort
        }
    }

    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case running(port: Int, version: String)
        case failed(String)
    }

    public enum EngineError: LocalizedError {
        case missingBinary(String)
        case noFreePort
        case didNotStart(String)

        public var errorDescription: String? {
            switch self {
            case let .missingBinary(path): "O motor de IA não foi encontrado em \(path)."
            case .noFreePort: "Nenhuma porta livre para o motor de IA."
            case let .didNotStart(detail): "O motor de IA não iniciou: \(detail)"
            }
        }
    }

    public nonisolated let configuration: Configuration
    public private(set) var state: State = .stopped
    private var process: Process?
    private var startTask: Task<Int, Error>?
    private var stateObservers: [UUID: AsyncStream<State>.Continuation] = [:]

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Estado atual e as mudanças seguintes.
    public func states() -> AsyncStream<State> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<State>.makeStream(bufferingPolicy: .bufferingNewest(8))
        continuation.yield(state)
        stateObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) {
        stateObservers[id] = nil
    }

    private func setState(_ newState: State) {
        guard newState != state else { return }
        state = newState
        for continuation in stateObservers.values { continuation.yield(newState) }
    }

    /// Garante o motor no ar e devolve a porta. Chamadas simultâneas esperam a mesma inicialização.
    @discardableResult
    public func start() async throws -> Int {
        if case let .running(port, _) = state, process?.isRunning == true { return port }
        if let startTask { return try await startTask.value }

        let task = Task { try await launch() }
        startTask = task
        defer { startTask = nil }
        do {
            return try await task.value
        } catch {
            setState(.failed(error.localizedDescription))
            throw error
        }
    }

    public func stop() async {
        startTask?.cancel()
        guard let process else {
            setState(.stopped)
            return
        }
        self.process = nil
        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
            for _ in 0..<20 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: configuration.pidFile)
        setState(.stopped)
    }

    private func launch() async throws -> Int {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: configuration.binary.path) else {
            throw EngineError.missingBinary(configuration.binary.path)
        }
        setState(.starting)

        for directory in [configuration.modelsDirectory, configuration.homeDirectory] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        terminateLeftover()
        Self.clearQuarantine(nextTo: configuration.binary)

        guard let port = Self.freePort(startingAt: configuration.preferredPort) else { throw EngineError.noFreePort }

        manager.createFile(atPath: configuration.logFile.path, contents: nil)
        let log = try FileHandle(forWritingTo: configuration.logFile)

        // O motor roda sob um vigia em sh: se o app morrer de repente (travamento, "Forçar encerrar"),
        // o vigia encerra o Ollama em até 1 s e o modelo não fica ocupando memória.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.watchdog, "libras-ollama", configuration.binary.path, configuration.pidFile.path, String(getpid())]
        process.currentDirectoryURL = configuration.binary.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["OLLAMA_HOST"] = "127.0.0.1:\(port)"
        environment["OLLAMA_MODELS"] = configuration.modelsDirectory.path
        environment["HOME"] = configuration.homeDirectory.path
        environment["OLLAMA_MAX_LOADED_MODELS"] = "1"
        environment["OLLAMA_NUM_PARALLEL"] = "1"
        environment["OLLAMA_KEEP_ALIVE"] = "30m"
        environment["OLLAMA_NOHISTORY"] = "1"
        environment.removeValue(forKey: "OLLAMA_ORIGINS")
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { await self?.processExited(finished, status: status) }
        }

        try process.run()
        self.process = process

        // Executáveis novos (app recém-instalado) passam pela conferência do macOS na primeira execução: uns 30 s.
        let client = OllamaClient(port: port)
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            try Task.checkCancellation()
            guard process.isRunning else {
                throw EngineError.didNotStart(Self.lastLines(of: configuration.logFile) ?? "o processo terminou")
            }
            if let version = try? await client.version() {
                setState(.running(port: port, version: version))
                return port
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        process.terminate()
        throw EngineError.didNotStart("tempo esgotado")
    }

    private func processExited(_ finished: Process, status: Int32) {
        guard finished === process else { return }
        process = nil
        try? FileManager.default.removeItem(at: configuration.pidFile)
        let detail = Self.lastLines(of: configuration.logFile) ?? "código \(status)"
        setState(.failed("O motor de IA parou (\(detail))."))
    }

    /// Um motor que ficou aberto porque o app fechou de repente: encerra antes de subir outro.
    private func terminateLeftover() {
        guard let text = try? String(contentsOf: configuration.pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return }
        defer { try? FileManager.default.removeItem(at: configuration.pidFile) }
        guard kill(pid, 0) == 0, Self.executablePath(of: pid) == configuration.binary.resolvingSymlinksInPath().path else { return }
        kill(pid, SIGTERM)
        for _ in 0..<20 where kill(pid, 0) == 0 {
            usleep(100_000)
        }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// App baixado da internet: o macOS marca todos os arquivos com quarentena. Liberar o app em
    /// Privacidade e Segurança vale para ele, mas os executáveis do Ollama dentro dele seriam barrados
    /// ao rodar. Tira a marca só deles (sem efeito se o app estiver numa pasta só de leitura).
    static func clearQuarantine(nextTo binary: URL) {
        let folder = binary.deletingLastPathComponent()
        for name in [binary.lastPathComponent, "llama-server"] {
            removexattr(folder.appendingPathComponent(name).path, "com.apple.quarantine", 0)
        }
    }

    /// $1 = executável do Ollama, $2 = arquivo com o PID do motor, $3 = PID do app.
    static let watchdog = """
    "$1" serve &
    child=$!
    echo "$child" > "$2"
    trap 'kill -TERM "$child" 2>/dev/null; wait "$child"; exit 0' TERM INT HUP
    while kill -0 "$3" 2>/dev/null && kill -0 "$child" 2>/dev/null; do
      sleep 1 & wait $!
    done
    kill -TERM "$child" 2>/dev/null
    wait "$child"
    """

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }

    /// Primeira porta livre em 127.0.0.1 a partir de `start`.
    static func freePort(startingAt start: Int) -> Int? {
        for port in start..<(start + 40) where isFree(port: port) {
            return port
        }
        return nil
    }

    static func isFree(port: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    static func lastLines(of url: URL, count: Int = 2) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).suffix(count).map(String.init)
        return lines.isEmpty ? nil : lines.joined(separator: " · ")
    }
}
