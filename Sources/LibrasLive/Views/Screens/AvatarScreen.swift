import LibrasCore
import SwiftUI

struct AvatarScreen: View {
    @Environment(AppModel.self) private var model
    @AppStorage("LibrasLive.showAvatarPreview") private var showPreview = true

    var body: some View {
        GeometryReader { proxy in
            let sideBySide = proxy.size.width >= 760
            HStack(alignment: .top, spacing: 0) {
                form(inlinePreview: !sideBySide)
                if sideBySide {
                    previewColumn
                        .frame(width: (proxy.size.width * 0.3).rounded().clamped(to: 230...340))
                        .padding(.vertical, 20)
                        .padding(.trailing, 20)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }

    private var previewColumn: some View {
        VStack(spacing: 10) {
            AvatarStage(url: model.previewURL, enabled: showPreview)
            previewCaption
        }
    }

    private var previewCaption: some View {
        Text("Prévia ao vivo · as mudanças chegam ao OBS na hora")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    private func form(inlinePreview: Bool) -> some View {
        @Bindable var model = model

        return Form {
            if inlinePreview {
                Section {
                    VStack(spacing: 8) {
                        AvatarStage(url: model.previewURL, enabled: showPreview, cornerRadius: 14)
                            .frame(height: 300)
                        previewCaption
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
            }

            Section("Personagem") {
                HStack(spacing: 12) {
                    ForEach(Avatar.allCases) { avatar in
                        AvatarCard(avatar: avatar, isSelected: model.settings.avatar == avatar) {
                            model.settings.avatar = avatar
                        }
                    }
                }
                .padding(.vertical, 6)
                Toggle("Legenda do próprio avatar", isOn: $model.settings.subtitles)
            }

            Section {
                Toggle("Personalizar cores e logo", isOn: $model.settings.appearance.enabled.animation())
            } footer: {
                if !model.settings.appearance.enabled {
                    Text("Troque a cor da roupa, da pele e do cabelo e coloque a sua logo na camisa.")
                }
            }

            if model.settings.appearance.enabled {
                Section {
                    ColorRow(title: "Camisa", hex: $model.settings.appearance.shirt)
                    ColorRow(title: "Calça", hex: $model.settings.appearance.pants)
                    ColorRow(title: "Pele", hex: $model.settings.appearance.skin)
                    ColorRow(title: "Cabelo", hex: $model.settings.appearance.hair)
                    ColorRow(title: "Sobrancelhas", hex: $model.settings.appearance.eyebrows)
                    ColorRow(title: "Íris", hex: $model.settings.appearance.iris)
                    ColorRow(title: "Branco dos olhos", hex: $model.settings.appearance.eyes)
                } header: {
                    HStack {
                        Text("Cores")
                        Spacer()
                        Button("Restaurar") { model.resetAppearanceColors() }
                            .buttonStyle(.borderless)
                            .font(.callout)
                    }
                }

                Section {
                    Picker("Logo na camisa", selection: $model.settings.appearance.logoMode) {
                        Text("VLibras").tag(AvatarAppearance.LogoMode.vlibras)
                        Text("Minha logo").tag(AvatarAppearance.LogoMode.custom)
                        Text("Sem logo").tag(AvatarAppearance.LogoMode.none)
                    }
                    .pickerStyle(.segmented)

                    if model.settings.appearance.logoMode == .custom {
                        LogoWell(
                            imageURL: model.logoPreviewURL,
                            version: model.logoVersion,
                            onChoose: { model.chooseLogo() },
                            onDrop: { model.importLogo(from: $0) }
                        )
                        .padding(.vertical, 4)

                        if let warning = model.appearanceWarning {
                            Callout(kind: .warning, message: warning)
                        }

                        Picker("Posição", selection: $model.settings.appearance.logoPosition) {
                            Text("Peito").tag(AvatarAppearance.LogoPosition.chest)
                            Text("Centro").tag(AvatarAppearance.LogoPosition.center)
                            Text("Peito e centro").tag(AvatarAppearance.LogoPosition.centerAndChest)
                        }

                        LabeledContent("Tamanho") {
                            HStack {
                                Slider(value: $model.settings.appearance.logoScale, in: 0.3...1, step: 0.05)
                                Text("\(Int((model.settings.appearance.logoScale * 100).rounded()))%")
                                    .monospacedDigit()
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                        OffsetControl(title: "Horizontal", value: $model.settings.appearance.logoOffsetX, minimum: "Esquerda", maximum: "Direita")
                        OffsetControl(title: "Vertical", value: $model.settings.appearance.logoOffsetY, minimum: "Baixo", maximum: "Cima")
                    }
                } header: {
                    Text("Logo")
                } footer: {
                    Text("A personalização oficial do VLibras é para instituições parceiras. Confirme o uso da sua logo antes de transmitir.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct OffsetControl: View {
    let title: String
    @Binding var value: Double
    let minimum: String
    let maximum: String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: -1...1, step: 0.05) {
                    Text(title)
                } minimumValueLabel: {
                    Text(minimum).font(.caption2).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text(maximum).font(.caption2).foregroundStyle(.secondary)
                }
                .labelsHidden()
                Button {
                    value = 0
                } label: {
                    Image(systemName: "scope")
                }
                .buttonStyle(.borderless)
                .help("Centralizar")
                .disabled(value == 0)
            }
        }
    }
}
