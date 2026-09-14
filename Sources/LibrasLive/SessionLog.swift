import Foundation
import LibrasCore

/// Log da sessão em JSON Lines: uma linha por evento, gravada fora da thread principal.
///
/// Um arquivo por sessão em `~/Library/Application Support/LibrasLive/logs/`.
@MainActor
final class SessionLog {
    nonisolated static var directory: URL { AppPaths.support.appendingPathComponent("logs", isDirectory: true) }

    private(set) var fileURL: URL
    private(set) var eventCount = 0
    var isEnabled = true

    private let writer = LogFileWriter()
    private let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init() {
        fileURL = Self.newFileURL()
    }

    /// Registra um evento. Valores precisam ser serializáveis em JSON (String, números, Bool, arrays, dicionários).
    func record(_ event: String, _ fields: [String: Any] = [:]) {
        guard isEnabled else { return }
        var object = fields
        object["ev"] = event
        object["t"] = iso.string(from: Date())
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        eventCount += 1
        writer.append(data, to: fileURL)
    }

    /// Conteúdo da sessão atual, depois de gravar o que estiver pendente.
    func currentContents() async -> String {
        await writer.contents(of: fileURL)
    }

    /// Salva `<nome>.txt` (legível) e `<nome>.jsonl` (dados completos) no destino escolhido.
    func export(to textURL: URL) async throws {
        let contents = await currentContents()
        try SessionLogFormatter.format(contents).write(to: textURL, atomically: true, encoding: .utf8)
        let jsonURL = textURL.deletingPathExtension().appendingPathExtension("jsonl")
        try contents.write(to: jsonURL, atomically: true, encoding: .utf8)
    }

    /// Apaga todos os logs e começa um arquivo novo.
    func clearAll() async {
        await writer.removeDirectory(Self.directory)
        fileURL = Self.newFileURL()
        eventCount = 0
    }

    /// Apaga sessões anteriores em que nada aconteceu (o app abriu e fechou sem ouvir nem traduzir).
    nonisolated static func pruneIdleSessions(keeping current: URL) async {
        await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let urls = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for url in urls where url.pathExtension == "jsonl" && url.standardizedFileURL != current.standardizedFileURL {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size < 64_000, let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if !activityEvents.contains(where: { text.contains("\"ev\":\"\($0)\"") }) {
                    try? manager.removeItem(at: url)
                }
            }
        }.value
    }

    private nonisolated static let activityEvents = ["listen.start", "enqueue", "commit", "dispatch", "drop", "error"]

    private static func newFileURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return directory.appendingPathComponent("sessao-\(formatter.string(from: Date())).jsonl")
    }
}

/// Gravação serializada numa fila própria; o estado só é tocado dentro dela.
private final class LogFileWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LibrasLive.SessionLog", qos: .utility)
    private var handle: FileHandle?
    private var handleURL: URL?

    func append(_ data: Data, to url: URL) {
        queue.async {
            self.openIfNeeded(url)
            try? self.handle?.write(contentsOf: data)
        }
    }

    func contents(of url: URL) async -> String {
        await withCheckedContinuation { continuation in
            queue.async {
                try? self.handle?.synchronize()
                continuation.resume(returning: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
            }
        }
    }

    func removeDirectory(_ directory: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                try? self.handle?.close()
                self.handle = nil
                self.handleURL = nil
                try? FileManager.default.removeItem(at: directory)
                continuation.resume()
            }
        }
    }

    private func openIfNeeded(_ url: URL) {
        guard handleURL != url else { return }
        try? handle?.close()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        handleURL = url
    }
}
