import AppKit
import LibrasCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Uma única prévia do avatar para o app inteiro.
///
/// As telas pegam emprestado o mesmo `WKWebView`: trocar de tela (ou de layout ao redimensionar)
/// só muda a prévia de lugar, sem recarregar o Unity. Fora da tela o WebKit pausa a animação,
/// e ela volta na hora quando a prévia aparece de novo.
@MainActor
final class AvatarPreviewHost: NSObject, WKNavigationDelegate {
    static let shared = AvatarPreviewHost()

    private var webView: WKWebView?
    private var loadedURL: URL?
    private var retryTask: Task<Void, Never>?
    /// Lugares abertos, em ordem de chegada: o mais recente fica com a prévia.
    private var slots: [WeakSlot] = []

    private struct WeakSlot {
        weak var view: NSView?
    }

    /// Começa a carregar antes de alguma tela mostrar a prévia.
    func preload(_ url: URL) {
        _ = webView(for: url)
    }

    /// Uma tela abriu um lugar para a prévia.
    func adopt(_ slot: NSView, url: URL) {
        slots.removeAll { $0.view == nil || $0.view === slot }
        slots.append(WeakSlot(view: slot))
        place(url: url)
    }

    /// A tela atualizou: garante a URL certa e a prévia no lugar mais recente.
    func refresh(url: URL) {
        place(url: url)
    }

    /// Uma tela fechou o lugar; a prévia vai para o lugar anterior, se ainda existir.
    func abandon(_ slot: NSView) {
        slots.removeAll { $0.view == nil || $0.view === slot }
        if webView?.superview === slot {
            webView?.removeFromSuperview()
        }
        if let loadedURL { place(url: loadedURL) }
    }

    /// Prévia desligada nos Ajustes: fecha a página e libera o Unity.
    func release() {
        retryTask?.cancel()
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView?.navigationDelegate = nil
        webView = nil
        loadedURL = nil
    }

    private func place(url: URL) {
        guard let owner = slots.last?.view else { return }
        let webView = webView(for: url)
        guard webView.superview !== owner else { return }
        webView.removeFromSuperview()
        webView.frame = owner.bounds
        owner.addSubview(webView)
        owner.needsLayout = true
    }

    private func webView(for url: URL) -> WKWebView {
        let webView = self.webView ?? makeWebView()
        self.webView = webView
        if loadedURL != url {
            loadedURL = url
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    private func makeWebView() -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.navigationDelegate = self
        return webView
    }

    /// O servidor local pode ainda não estar no ar (abertura do app, troca de porta): tenta de novo.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        scheduleRetry(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        scheduleRetry(webView)
    }

    /// O processo do WebKit caiu (memória, GPU): recarrega sozinho.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        scheduleRetry(webView)
    }

    private func scheduleRetry(_ webView: WKWebView) {
        retryTask?.cancel()
        retryTask = Task { [weak self, weak webView] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, let webView, webView === self.webView, let url = self.loadedURL else { return }
            webView.load(URLRequest(url: url))
        }
    }
}

/// Lugar da prévia numa tela: recebe o `WKWebView` compartilhado enquanto a tela existe.
struct AvatarPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PreviewSlotView {
        let slot = PreviewSlotView()
        AvatarPreviewHost.shared.adopt(slot, url: url)
        return slot
    }

    func updateNSView(_ slot: PreviewSlotView, context: Context) {
        AvatarPreviewHost.shared.refresh(url: url)
    }

    static func dismantleNSView(_ slot: PreviewSlotView, coordinator: ()) {
        AvatarPreviewHost.shared.abandon(slot)
    }
}

/// Mantém a prévia do tamanho do lugar.
final class PreviewSlotView: NSView {
    override func layout() {
        super.layout()
        for subview in subviews {
            subview.frame = bounds
        }
    }
}

/// Moldura da prévia em 9:16, como um monitor: fundo escuro nos dois modos de aparência.
struct AvatarStage<Overlay: View>: View {
    let url: URL
    var enabled = true
    var cornerRadius: CGFloat = 18
    @ViewBuilder var overlay: Overlay

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.24), Color(white: 0.11)], startPoint: .top, endPoint: .bottom)
            if enabled {
                AvatarPreview(url: url)
            } else {
                ContentUnavailableView("Prévia desligada", systemImage: "eye.slash", description: Text("Ligue em Ajustes › Geral."))
                    .environment(\.colorScheme, .dark)
            }
            overlay
                .environment(\.colorScheme, .dark)
        }
        .aspectRatio(9 / 16, contentMode: .fit)
        .onChange(of: enabled, initial: true) { _, isEnabled in
            if !isEnabled { AvatarPreviewHost.shared.release() }
        }
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }
}

extension AvatarStage where Overlay == EmptyView {
    init(url: URL, enabled: Bool = true, cornerRadius: CGFloat = 18) {
        self.init(url: url, enabled: enabled, cornerRadius: cornerRadius) { EmptyView() }
    }
}

/// Cartão selecionável de personagem com miniatura.
struct AvatarCard: View {
    let avatar: Avatar
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.fill.quaternary))
                    if let image = AvatarArtwork.image(for: avatar) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .padding(.top, 8)
                    }
                }
                .frame(height: 132)
                .clipShape(.rect(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: isSelected ? 2.5 : 1)
                )

                HStack(spacing: 4) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                    }
                    Text(avatar.title).font(.callout.weight(isSelected ? .semibold : .regular))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(avatar.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

enum AvatarArtwork {
    static func image(for avatar: Avatar) -> NSImage? {
        let name = "\(avatar.rawValue).png"
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Avatars").appendingPathComponent(name))
        }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            dir.deleteLastPathComponent()
            candidates.append(dir.appendingPathComponent("Resources/Avatars").appendingPathComponent(name))
        }
        return candidates.lazy.compactMap { NSImage(contentsOf: $0) }.first
    }
}

/// Linha de cor: poço de cor + código hexadecimal editável.
struct ColorRow: View {
    let title: String
    @Binding var hex: String
    @State private var text = ""

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                TextField("Código de \(title.lowercased())", text: $text, prompt: Text("#RRGGBB"))
                    .labelsHidden()
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                    .frame(width: 84)
                    .onSubmit(applyText)
                ColorPicker(title, selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
            }
        }
        .onAppear { text = hex }
        .onChange(of: hex) { _, newValue in text = newValue }
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(hex: hex) }, set: { hex = $0.hexString })
    }

    private func applyText() {
        if let normalized = AvatarAppearance.normalizedHex(text) {
            hex = normalized
        } else {
            text = hex
        }
    }
}

/// Área da logo: miniatura sobre xadrez, escolher arquivo ou arrastar uma imagem.
struct LogoWell: View {
    let imageURL: URL?
    let version: Int
    let onChoose: () -> Void
    let onDrop: (URL) -> Void
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                CheckerboardBackground()
                if let imageURL, let image = NSImage(contentsOf: imageURL) {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                } else {
                    Image(systemName: "photo.badge.plus")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .id(version)
            .frame(width: 84, height: 84)
            .clipShape(.rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: imageURL == nil ? [5, 4] : []))
            )

            VStack(alignment: .leading, spacing: 6) {
                Button(imageURL == nil ? "Escolher imagem…" : "Trocar imagem…", action: onChoose)
                Text("Ou arraste um arquivo para cá. PNG com fundo transparente fica melhor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }) else { return false }
            onDrop(url)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.96)))
            for row in 0..<Int(size.height / cell) + 1 {
                for column in 0..<Int(size.width / cell) + 1 where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)), with: .color(Color(white: 0.86)))
                }
            }
        }
    }
}

extension Color {
    init(hex: String) {
        let normalized = AvatarAppearance.normalizedHex(hex) ?? "#000000"
        let value = Int(normalized.dropFirst(), radix: 16) ?? 0
        self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    var hexString: String {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        func channel(_ value: CGFloat) -> Int { max(0, min(255, Int((value * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", channel(color.redComponent), channel(color.greenComponent), channel(color.blueComponent))
    }
}
