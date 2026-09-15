// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LibrasLive",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "LibrasLive", targets: ["LibrasLive"]),
        .executable(name: "libras-probe", targets: ["LibrasProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        // Regras puras: segmentação, fila de sinais, protocolo, cliente de glosa.
        .target(name: "LibrasCore"),

        // Dispositivos de áudio (Core Audio) e captura por canal (AUHAL).
        .target(name: "AudioCapture"),

        // Reconhecimento de fala (SpeechAnalyzer).
        .target(name: "Transcription"),

        // Servidor HTTP + WebSocket do overlay e cache dos sinais.
        .target(
            name: "OverlayServer",
            dependencies: [
                "LibrasCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // IA local: motor Ollama embutido, modelos, busca na biblioteca e reescrita de frases.
        .target(name: "LocalAI", dependencies: ["LibrasCore"]),

        .executableTarget(
            name: "LibrasLive",
            dependencies: ["LibrasCore", "AudioCapture", "Transcription", "OverlayServer", "LocalAI"]
        ),

        // Diagnóstico por linha de comando: dispositivos, nível, transcrição de arquivo, glosa.
        .executableTarget(
            name: "LibrasProbe",
            dependencies: ["LibrasCore", "AudioCapture", "Transcription", "OverlayServer", "LocalAI"]
        ),

        .testTarget(name: "LibrasCoreTests", dependencies: ["LibrasCore"]),
        .testTarget(name: "OverlayServerTests", dependencies: ["OverlayServer"]),
        .testTarget(name: "LocalAITests", dependencies: ["LocalAI"]),
    ],
    swiftLanguageModes: [.v5]
)
