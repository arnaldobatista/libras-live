import Foundation
import Hummingbird
import HummingbirdWebSocket
import LibrasCore
import Logging

public enum OverlayServerEvent: Sendable {
    case running(port: Int)
    case failed(String)
    case clientConnected(UUID)
    case clientDisconnected(UUID)
    case inbound(OverlayInbound, client: UUID)
    /// Texto injetado por `POST /api/say` (testes, Stream Deck, automações).
    case say(String)
    /// `POST /api/clear`.
    case clearRequested
    /// `POST /api/appearance` com campos parciais.
    case appearance(AvatarAppearancePatch)
}

public struct OverlayServerConfiguration: Sendable {
    public var port: Int
    public var overlayDirectory: URL
    public var signCacheDirectory: URL
    public var signsUpstream: URL
    /// Pasta com `logo.png` e `blank.png` da aparência personalizada.
    public var appearanceDirectory: URL?

    public init(
        port: Int = 8765,
        overlayDirectory: URL,
        signCacheDirectory: URL,
        signsUpstream: URL = SignCache.defaultUpstream,
        appearanceDirectory: URL? = nil
    ) {
        self.port = port
        self.overlayDirectory = overlayDirectory
        self.signCacheDirectory = signCacheDirectory
        self.signsUpstream = signsUpstream
        self.appearanceDirectory = appearanceDirectory
    }
}

/// Servidor local do overlay:
///
/// - `GET /`            página do avatar (browser source do OBS)
/// - `WS  /ws`          canal de mensagens com o overlay
/// - `GET /signs/:nome` animações de sinais com cache em disco
/// - `POST /api/say`    `{ "text": "..." }` injeta fala
/// - `POST /api/clear`  limpa a fila
/// - `POST /api/appearance` `{ "shirt": "#000000", "logoPosition": "center", ... }` muda a aparência
/// - `GET /api/status`  estado atual em JSON
public final class OverlayServer: @unchecked Sendable {
    public let configuration: OverlayServerConfiguration
    public let events: AsyncStream<OverlayServerEvent>
    public let signCache: SignCache

    private let eventContinuation: AsyncStream<OverlayServerEvent>.Continuation
    private let hub = ConnectionHub()
    private let statusLock = NSLock()
    private var statusProvider: (@Sendable () async -> Data)?
    private var task: Task<Void, Never>?

    public init(configuration: OverlayServerConfiguration) {
        self.configuration = configuration
        signCache = SignCache(directory: configuration.signCacheDirectory, upstream: configuration.signsUpstream)
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(512))
    }

    public var overlayURL: URL {
        URL(string: "http://127.0.0.1:\(configuration.port)/")!
    }

    public var signsBaseURL: String {
        "http://127.0.0.1:\(configuration.port)/signs/"
    }

    public func setStatusProvider(_ provider: @escaping @Sendable () async -> Data) {
        statusLock.withLock { statusProvider = provider }
    }

    public func start() {
        guard task == nil else { return }
        let application = makeApplication()
        let events = eventContinuation
        task = Task.detached {
            do {
                try await application.runService(gracefulShutdownSignals: [])
            } catch is CancellationError {
            } catch {
                events.yield(.failed(error.localizedDescription))
            }
        }
    }

    public func stop() async {
        await hub.closeAll()
        task?.cancel()
        await task?.value
        task = nil
    }

    public func send(_ message: OverlayOutbound) async {
        if case .config = message {
            await hub.broadcastConfig(message.json())
        } else {
            await hub.broadcast(message.json())
        }
    }

    // MARK: Aplicação

    private func makeApplication() -> some ApplicationProtocol {
        var logger = Logger(label: "LibrasLive.OverlayServer")
        logger.logLevel = .warning

        let router = Router()
        router.add(middleware: LocalOnlyMiddleware(port: configuration.port))
        // HTML/JS/CSS/JSON sempre revalidados: o OBS não pode ficar com overlay antigo após atualizar o app.
        let revalidate: [CacheControl.CacheControlValue] = [.noCache]
        router.add(middleware: FileMiddleware(
            configuration.overlayDirectory.path,
            cacheControl: CacheControl([
                (.textHtml, revalidate),
                (.textJavascript, revalidate),
                (.textCss, revalidate),
                (.applicationJson, revalidate),
            ]),
            searchForIndexHtml: true,
            logger: logger
        ))
        addSignRoutes(to: router)
        addAppearanceRoutes(to: router)
        addAPIRoutes(to: router)

        let wsRouter = Router(context: BasicWebSocketRequestContext.self)
        let port = configuration.port
        wsRouter.ws("/ws", shouldUpgrade: { request, _ in
            // Só o próprio overlay (ou clientes sem Origin) pode abrir o canal.
            guard let host = request.head.authority, OriginPolicy.isLocalHost(host, port: port),
                  OriginPolicy.isAllowedOrigin(request.headers[.origin], port: port) else {
                return .dontUpgrade
            }
            return .upgrade([:])
        }) { [hub, eventContinuation] inbound, outbound, _ in
            let (id, outgoing) = await hub.add()
            eventContinuation.yield(.clientConnected(id))

            // Leitura em tarefa própria: quando o overlay fecha, remove o cliente e encerra o envio.
            let reader = Task {
                defer {
                    Task {
                        await hub.remove(id)
                        eventContinuation.yield(.clientDisconnected(id))
                    }
                }
                for try await message in inbound.messages(maxSize: 64 * 1024) {
                    guard case let .text(text) = message, let decoded = OverlayInbound.decode(text) else { continue }
                    eventContinuation.yield(.inbound(decoded, client: id))
                }
            }

            // Envio no próprio handler. O stream termina quando o overlay desconecta
            // ou o servidor fecha tudo; retornar fecha o WebSocket sem esperar a leitura.
            for await text in outgoing {
                try await outbound.write(.text(text))
            }
            reader.cancel()
        }

        let events = eventContinuation
        return Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
            configuration: .init(address: .hostname("127.0.0.1", port: port), serverName: "LibrasLive"),
            onServerRunning: { _ in events.yield(.running(port: port)) },
            logger: logger
        )
    }

    private func addSignRoutes(to router: Router<BasicRequestContext>) {
        let cache = signCache
        router.get("/signs/:name") { _, context -> Response in
            guard let name = context.parameters.get("name")?.removingPercentEncoding else {
                return Response(status: .badRequest)
            }
            switch await cache.fetch(name) {
            case let .hit(data), let .downloaded(data):
                var headers = HTTPFields()
                headers[.contentType] = "application/octet-stream"
                headers[.cacheControl] = "public, max-age=86400"
                headers[.accessControlAllowOrigin] = "*"
                return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
            case .notFound:
                return Response(status: .notFound)
            case .failed:
                return Response(status: .badGateway)
            }
        }
    }

    /// `GET /appearance/logo.png` e `/appearance/blank.png`: imagens da camisa do avatar.
    private func addAppearanceRoutes(to router: Router<BasicRequestContext>) {
        let directory = configuration.appearanceDirectory
        router.get("/appearance/:file") { _, context -> Response in
            guard let directory, let file = context.parameters.get("file"),
                  ["logo.png", "blank.png"].contains(file),
                  let data = try? Data(contentsOf: directory.appendingPathComponent(file)) else {
                return Response(status: .notFound)
            }
            var headers = HTTPFields()
            headers[.contentType] = "image/png"
            headers[.cacheControl] = "no-cache"
            return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
        }
    }

    private func addAPIRoutes(to router: Router<BasicRequestContext>) {
        struct SayRequest: Decodable { let text: String }

        router.post("/api/say") { [eventContinuation] request, context -> HTTPResponse.Status in
            let body = try await request.decode(as: SayRequest.self, context: context)
            let text = body.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .badRequest }
            eventContinuation.yield(.say(text))
            return .accepted
        }

        router.post("/api/appearance") { [eventContinuation] request, context -> HTTPResponse.Status in
            let patch = try await request.decode(as: AvatarAppearancePatch.self, context: context)
            eventContinuation.yield(.appearance(patch))
            return .accepted
        }

        router.post("/api/clear") { [eventContinuation] _, _ -> HTTPResponse.Status in
            eventContinuation.yield(.clearRequested)
            return .accepted
        }

        router.get("/api/status") { [weak self] _, _ -> Response in
            let provider = self?.statusLock.withLock { self?.statusProvider }
            let data = await provider?() ?? Data("{}".utf8)
            var headers = HTTPFields()
            headers[.contentType] = "application/json; charset=utf-8"
            return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
        }
    }
}
