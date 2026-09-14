import Hummingbird

/// Protege o servidor local contra páginas de terceiros abertas no navegador.
///
/// - `Host` (authority) precisa ser local (bloqueia DNS rebinding).
/// - Requisições que alteram estado (`POST`) com `Origin` só são aceitas da própria origem.
/// - `POST` exige `Content-Type: application/json`, o que força o preflight de CORS
///   (que este servidor não autoriza) em chamadas vindas de outros sites.
///
/// Ferramentas locais (curl, Stream Deck, scripts) não enviam `Origin` e continuam funcionando.
struct LocalOnlyMiddleware<Context: RequestContext>: RouterMiddleware {
    let port: Int

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let host = request.head.authority, OriginPolicy.isLocalHost(host, port: port) else {
            return Response(status: .forbidden)
        }

        if request.method == .post {
            if let origin = request.headers[.origin], !OriginPolicy.isAllowedOrigin(origin, port: port) {
                return Response(status: .forbidden)
            }
            let contentType = request.headers[.contentType]?.lowercased() ?? ""
            guard contentType.hasPrefix("application/json") else {
                return Response(status: .unsupportedMediaType)
            }
        }

        return try await next(request, context)
    }
}

enum OriginPolicy {
    static func localHosts(port: Int) -> Set<String> {
        ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"]
    }

    static func isLocalHost(_ host: String, port: Int) -> Bool {
        localHosts(port: port).contains(host.lowercased())
    }

    /// Sem `Origin` (OBS antigo, ferramentas) ou a própria origem do overlay.
    static func isAllowedOrigin(_ origin: String?, port: Int) -> Bool {
        guard let origin, origin != "null" else { return origin == nil }
        return localHosts(port: port).contains { origin.lowercased() == "http://\($0)" }
    }
}
