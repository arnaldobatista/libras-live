import AudioToolbox
import CoreAudio
import os

/// Mede o pico de **cada** canal de um dispositivo, sem mapa de canais.
///
/// Serve para descobrir em qual canal da mesa está a voz: a interface mostra um
/// medidor por canal enquanto o usuário escolhe.
public final class ChannelScanner: @unchecked Sendable {
    public typealias LevelsHandler = ([Float]) -> Void

    public let device: AudioDevice

    private var unit: AudioUnit?
    private var bufferList: UnsafeMutableAudioBufferListPointer?
    private var storage: [UnsafeMutablePointer<Float32>] = []
    private var capacityFrames: UInt32 = 0
    private var peaks: [Float] = []
    private var framesSinceReport = 0
    private var reportEvery = 4800
    private var onLevels: LevelsHandler?

    public init(device: AudioDevice) {
        self.device = device
    }

    deinit {
        stop()
    }

    /// - Parameter onLevels: picos lineares (0…1) por canal, ~10 vezes por segundo, na thread de áudio.
    public func start(onLevels: @escaping LevelsHandler) throws {
        stop()
        self.onLevels = onLevels
        let channels = device.inputChannels
        peaks = [Float](repeating: 0, count: channels)

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

        do {
            var enable: UInt32 = 1
            var disable: UInt32 = 0
            try check("habilitar entrada", AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, 4))
            try check("desabilitar saída", AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, 4))

            var deviceID = device.id
            try check("selecionar dispositivo", AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)))

            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check("ler formato", AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size))
            let sampleRate = hardware.mSampleRate > 0 ? hardware.mSampleRate : 48_000

            var client = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0
            )
            try check("definir formato", AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size))

            var callback = AURenderCallbackStruct(
                inputProc: channelScannerInputProc,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try check("registrar callback", AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

            try check("inicializar", AudioUnitInitialize(unit))

            var maxFrames: UInt32 = 0
            var maxSize = UInt32(MemoryLayout<UInt32>.size)
            AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &maxSize)
            capacityFrames = max(maxFrames, 8192)
            let list = AudioBufferList.allocate(maximumBuffers: channels)
            storage = (0..<channels).map { _ in
                let pointer = UnsafeMutablePointer<Float32>.allocate(capacity: Int(capacityFrames))
                pointer.initialize(repeating: 0, count: Int(capacityFrames))
                return pointer
            }
            for index in 0..<channels {
                list[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: capacityFrames * 4, mData: UnsafeMutableRawPointer(storage[index]))
            }
            bufferList = list
            reportEvery = Int(sampleRate / 10)

            try check("iniciar", AudioOutputUnitStart(unit))
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        storage.forEach { $0.deallocate() }
        storage = []
        bufferList.map { free($0.unsafeMutablePointer) }
        bufferList = nil
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw CaptureError.coreAudio(step, status) }
    }

    fileprivate func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timeStamp: UnsafePointer<AudioTimeStamp>, frames: UInt32) -> OSStatus {
        guard let unit, let bufferList, frames <= capacityFrames else { return noErr }
        for index in 0..<bufferList.count {
            bufferList[index].mDataByteSize = frames * 4
            bufferList[index].mData = UnsafeMutableRawPointer(storage[index])
        }
        let status = AudioUnitRender(unit, flags, timeStamp, 1, frames, bufferList.unsafeMutablePointer)
        guard status == noErr else { return status }

        for (channel, samples) in storage.enumerated() {
            var peak = peaks[channel]
            for frame in 0..<Int(frames) { peak = max(peak, abs(samples[frame])) }
            peaks[channel] = peak
        }

        framesSinceReport += Int(frames)
        if framesSinceReport >= reportEvery {
            onLevels?(peaks)
            for index in peaks.indices { peaks[index] = 0 }
            framesSinceReport = 0
        }
        return noErr
    }
}

private func channelScannerInputProc(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    Unmanaged<ChannelScanner>.fromOpaque(inRefCon).takeUnretainedValue()
        .render(flags: ioActionFlags, timeStamp: inTimeStamp, frames: inNumberFrames)
}
