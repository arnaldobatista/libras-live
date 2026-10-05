import CoreAudio
import Foundation

/// Dispositivo de entrada de áudio do macOS.
public struct AudioDevice: Identifiable, Hashable, Sendable {
    /// ID do Core Audio. Muda entre reinícios; use `uid` para persistir.
    public let id: AudioDeviceID
    /// Identificador estável do dispositivo.
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let sampleRate: Double
    /// Nome de cada canal (quando o driver informa), índice 0 = canal 1.
    public let channelNames: [String?]

    public func label(forChannel index: Int) -> String {
        if index < channelNames.count, let name = channelNames[index], !name.isEmpty {
            return "\(index + 1) · \(name)"
        }
        return "\(index + 1)"
    }
}

public enum AudioDevices {
    /// Lista os dispositivos com pelo menos um canal de entrada.
    public static func inputDevices() -> [AudioDevice] {
        deviceIDs().compactMap(makeDevice(id:)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func device(uid: String) -> AudioDevice? {
        inputDevices().first { $0.uid == uid }
    }

    public static func defaultInputDevice() -> AudioDevice? {
        var id = AudioDeviceID(0)
        guard getValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, &id) == noErr else {
            return nil
        }
        return makeDevice(id: id)
    }

    // MARK: Privado

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func makeDevice(id: AudioDeviceID) -> AudioDevice? {
        let channels = inputChannelCount(id: id)
        guard channels > 0 else { return nil }

        let name = stringValue(id, kAudioObjectPropertyName) ?? "Dispositivo \(id)"
        let uid = stringValue(id, kAudioDevicePropertyDeviceUID) ?? "id-\(id)"
        var rate: Float64 = 0
        _ = getValue(id, kAudioDevicePropertyNominalSampleRate, &rate)

        let names: [String?] = (0..<channels).map { index in
            stringValue(id, kAudioObjectPropertyElementName, scope: kAudioObjectPropertyScopeInput, element: UInt32(index + 1))
                .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        }

        return AudioDevice(id: id, uid: uid, name: name, inputChannels: channels, sampleRate: rate, channelNames: names)
    }

    private static func inputChannelCount(id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Lê uma propriedade de valor simples (número, ID). Só tipos sem referências: o Core Audio copia os bytes.
    static func getValue<T: BitwiseCopyable>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ value: inout T,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    }

    private static func stringValue(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }
}

/// Avisa quando dispositivos são conectados ou removidos.
public final class AudioDeviceObserver {
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private let block: AudioObjectPropertyListenerBlock

    public init(onChange: @escaping () -> Void) {
        block = { _, _ in onChange() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }
}
