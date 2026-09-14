import AudioToolbox
import AVFoundation
import CoreAudio
import os

/// Nível de áudio linear (0…1).
public struct AudioLevel: Sendable, Equatable {
    public var rms: Float
    public var peak: Float

    public static let silence = AudioLevel(rms: 0, peak: 0)

    public init(rms: Float, peak: Float) {
        self.rms = rms
        self.peak = peak
    }

    /// Converte para dBFS, limitado em -60.
    public static func decibels(_ value: Float) -> Float {
        value > 0 ? max(-60, 20 * log10(value)) : -60
    }
}

public enum CaptureError: Error, LocalizedError {
    case noChannelsSelected
    case channelOutOfRange(Int, available: Int)
    case audioUnitNotFound
    case coreAudio(String, OSStatus)

    public var errorDescription: String? {
        switch self {
        case .noChannelsSelected:
            "Selecione pelo menos um canal."
        case let .channelOutOfRange(channel, available):
            "Canal \(channel + 1) não existe (o dispositivo tem \(available))."
        case .audioUnitNotFound:
            "AUHAL indisponível."
        case let .coreAudio(step, status):
            "Core Audio falhou em \(step) (código \(status))."
        }
    }
}

/// Captura um ou mais canais de um dispositivo de entrada e entrega mono Float32.
///
/// Usa o AUHAL com mapa de canais: o Core Audio entrega só os canais escolhidos,
/// então uma mesa de 32 canais custa o mesmo que um microfone.
public final class ChannelCapture: @unchecked Sendable {
    public typealias BufferHandler = (AVAudioPCMBuffer) -> Void
    public typealias LevelHandler = (AudioLevel) -> Void
    public typealias InterruptionHandler = (String) -> Void

    public let device: AudioDevice
    public let channels: [Int]
    public private(set) var format: AVAudioFormat?

    private let gainLock = OSAllocatedUnfairLock(initialState: Float(1))
    private var unit: AudioUnit?
    private var bufferList: UnsafeMutableAudioBufferListPointer?
    private var channelStorage: [UnsafeMutablePointer<Float32>] = []
    private var capacityFrames: UInt32 = 0

    private var onBuffer: BufferHandler?
    private var onLevel: LevelHandler?
    private var onInterruption: InterruptionHandler?

    private var levelSumSquares: Float = 0
    private var levelPeak: Float = 0
    private var levelFrames = 0
    private var levelWindow = 2400

    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    /// - Parameters:
    ///   - channels: índices 0-based dos canais do dispositivo; são somados em mono.
    ///   - gain: ganho linear aplicado após a soma.
    public init(device: AudioDevice, channels: [Int], gain: Float = 1) {
        self.device = device
        self.channels = Array(Set(channels)).sorted()
        gainLock.withLock { $0 = gain }
    }

    deinit {
        stop()
    }

    public var gain: Float {
        get { gainLock.withLock { $0 } }
        set { gainLock.withLock { $0 = newValue } }
    }

    public var isRunning: Bool { unit != nil }

    public func start(
        onBuffer: @escaping BufferHandler,
        onLevel: LevelHandler? = nil,
        onInterruption: InterruptionHandler? = nil
    ) throws {
        stop()
        guard !channels.isEmpty else { throw CaptureError.noChannelsSelected }
        if let invalid = channels.first(where: { $0 < 0 || $0 >= device.inputChannels }) {
            throw CaptureError.channelOutOfRange(invalid, available: device.inputChannels)
        }

        self.onBuffer = onBuffer
        self.onLevel = onLevel
        self.onInterruption = onInterruption

        do {
            try configureUnit()
            installDeviceListeners()
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        removeDeviceListeners()
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        channelStorage.forEach { $0.deallocate() }
        channelStorage = []
        bufferList.map { free($0.unsafeMutablePointer) }
        bufferList = nil
    }

    // MARK: Configuração do AUHAL

    private func configureUnit() throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { throw CaptureError.audioUnitNotFound }

        var instance: AudioUnit?
        try check("criar AUHAL", AudioComponentInstanceNew(component, &instance))
        guard let unit = instance else { throw CaptureError.audioUnitNotFound }
        self.unit = unit

        var enable: UInt32 = 1
        var disable: UInt32 = 0
        try check("habilitar entrada", AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size)))
        try check("desabilitar saída", AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size)))

        var deviceID = device.id
        try check("selecionar dispositivo", AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)))

        var hardware = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check("ler formato do dispositivo", AudioUnitGetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &asbdSize))

        let sampleRate = hardware.mSampleRate > 0 ? hardware.mSampleRate : 48_000
        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels.count),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        try check("definir formato de captura", AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, asbdSize))

        // Mapa de canais: posição = canal entregue, valor = canal do dispositivo.
        var map = channels.map { Int32($0) }
        try check("mapear canais", AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1, &map,
            UInt32(MemoryLayout<Int32>.size * map.count)))

        var callback = AURenderCallbackStruct(
            inputProc: channelCaptureInputProc,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try check("registrar callback", AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

        try check("inicializar", AudioUnitInitialize(unit))

        var maxFrames: UInt32 = 0
        var maxSize = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &maxSize)
        allocateBuffers(frames: max(maxFrames, 8192))

        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        levelWindow = Int(sampleRate / 20)

        try check("iniciar captura", AudioOutputUnitStart(unit))
    }

    private func allocateBuffers(frames: UInt32) {
        capacityFrames = frames
        let list = AudioBufferList.allocate(maximumBuffers: channels.count)
        channelStorage = channels.map { _ in
            let pointer = UnsafeMutablePointer<Float32>.allocate(capacity: Int(frames))
            pointer.initialize(repeating: 0, count: Int(frames))
            return pointer
        }
        for index in 0..<channels.count {
            list[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: UnsafeMutableRawPointer(channelStorage[index]))
        }
        bufferList = list
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw CaptureError.coreAudio(step, status) }
    }

    // MARK: Thread de áudio

    fileprivate func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        frames: UInt32
    ) -> OSStatus {
        guard let unit, let bufferList, let format else { return noErr }
        guard frames <= capacityFrames else { return kAudioUnitErr_TooManyFramesToProcess }

        for index in 0..<bufferList.count {
            bufferList[index].mDataByteSize = frames * 4
            bufferList[index].mData = UnsafeMutableRawPointer(channelStorage[index])
        }

        let status = AudioUnitRender(unit, flags, timeStamp, 1, frames, bufferList.unsafeMutablePointer)
        guard status == noErr else { return status }

        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let destination = output.floatChannelData?[0] else { return noErr }
        output.frameLength = frames

        let gain = self.gain
        let count = Int(frames)
        var sumSquares: Float = 0
        var peak: Float = 0

        for frame in 0..<count {
            var sample: Float = 0
            for storage in channelStorage { sample += storage[frame] }
            sample = min(1, max(-1, sample * gain))
            destination[frame] = sample
            sumSquares += sample * sample
            peak = max(peak, abs(sample))
        }

        onBuffer?(output)
        accumulateLevel(sumSquares: sumSquares, peak: peak, frames: count)
        return noErr
    }

    private func accumulateLevel(sumSquares: Float, peak: Float, frames: Int) {
        guard let onLevel else { return }
        levelSumSquares += sumSquares
        levelPeak = max(levelPeak, peak)
        levelFrames += frames
        guard levelFrames >= levelWindow else { return }

        onLevel(AudioLevel(rms: sqrt(levelSumSquares / Float(levelFrames)), peak: levelPeak))
        levelSumSquares = 0
        levelPeak = 0
        levelFrames = 0
    }

    // MARK: Mudanças no dispositivo

    private func installDeviceListeners() {
        let watched: [(AudioObjectPropertySelector, String)] = [
            (kAudioDevicePropertyDeviceIsAlive, "O dispositivo foi desconectado."),
            (kAudioDevicePropertyNominalSampleRate, "A taxa de amostragem do dispositivo mudou."),
            (kAudioDevicePropertyStreamConfiguration, "A configuração de canais do dispositivo mudou."),
        ]
        for (selector, message) in watched {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: selector == kAudioDevicePropertyStreamConfiguration ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.onInterruption?(message)
            }
            if AudioObjectAddPropertyListenerBlock(device.id, &address, .main, block) == noErr {
                listeners.append((address, block))
            }
        }
    }

    private func removeDeviceListeners() {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device.id, &address, .main, block)
        }
        listeners = []
    }
}

private func channelCaptureInputProc(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let capture = Unmanaged<ChannelCapture>.fromOpaque(inRefCon).takeUnretainedValue()
    return capture.render(flags: ioActionFlags, timeStamp: inTimeStamp, frames: inNumberFrames)
}
