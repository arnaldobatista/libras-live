import AudioCapture
import SwiftUI

/// Medidor horizontal de nível (RMS com marca de pico).
struct LevelMeter: View {
    let level: AudioLevel
    let active: Bool
    var showsValue = true

    var body: some View {
        let rms = AudioLevel.decibels(level.rms)
        let peak = AudioLevel.decibels(level.peak)

        HStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.fill.tertiary)
                    Capsule()
                        .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: proxy.size.width * fraction(rms))
                        }
                    Capsule()
                        .fill(.primary.opacity(0.7))
                        .frame(width: 2)
                        .offset(x: max(0, proxy.size.width * fraction(peak) - 2))
                }
                .animation(.linear(duration: 0.08), value: rms)
            }
            .frame(height: 8)
            .opacity(active ? 1 : 0.35)

            if showsValue {
                Text(active ? String(format: "%.0f dB", peak) : "parado")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(peak > -3 ? .red : .secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Nível de áudio")
        .accessibilityValue(active ? String(format: "%.0f decibéis", peak) : "Sem captura")
    }

    private func fraction(_ db: Float) -> CGFloat {
        CGFloat((db + 60) / 60).clamped(to: 0...1)
    }
}

/// Mostra se o detector de voz está ouvindo fala agora.
struct VoiceIndicator: View {
    let voiceDetected: Bool
    let active: Bool

    var body: some View {
        Label {
            Text(!active ? "Sem escuta" : (voiceDetected ? "Voz" : "Silêncio"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: voiceDetected && active ? "waveform" : "waveform.slash")
                .foregroundStyle(voiceDetected && active ? Color.green : Color.secondary)
                .symbolEffect(.variableColor.iterative, isActive: voiceDetected && active)
        }
        .frame(minWidth: 84, alignment: .leading)
        .help("Detector de voz usado para confirmar trechos nas pausas")
    }
}

/// Grade de canais do dispositivo, com atividade de cada canal enquanto monitora.
struct ChannelGrid: View {
    let device: AudioDevice
    let selected: Set<Int>
    let peaks: [Float]
    let toggle: (Int) -> Void

    private let columns = [GridItem(.adaptive(minimum: 44, maximum: 56), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(0..<device.inputChannels, id: \.self) { index in
                let isOn = selected.contains(index)
                Button {
                    toggle(index)
                } label: {
                    VStack(spacing: 4) {
                        Text("\(index + 1)")
                            .font(.system(.callout, design: .rounded).weight(isOn ? .semibold : .regular).monospacedDigit())
                        Capsule()
                            .fill(activityColor(index))
                            .frame(width: 22 * activity(index), height: 3)
                            .frame(width: 22, height: 3, alignment: .leading)
                            .background(Capsule().fill(.fill.tertiary))
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .foregroundStyle(isOn ? Color.white : Color.primary)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.quaternary))
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(device.label(forChannel: index))
                .accessibilityLabel("Canal \(index + 1)")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }

    private func activity(_ index: Int) -> CGFloat {
        guard index < peaks.count else { return 0 }
        return CGFloat((AudioLevel.decibels(peaks[index]) + 60) / 60).clamped(to: 0...1)
    }

    private func activityColor(_ index: Int) -> Color {
        let value = activity(index)
        if value > 0.95 { return .red }
        return value > 0.1 ? .green : .clear
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
