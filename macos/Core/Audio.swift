import Foundation
import AVFoundation
import CoreAudio
import Darwin

public protocol AudioSamplesSource: AnyObject {
    var sampleRate: Double { get }
    var capturedFrames: Int64 { get }
    var droppedFrames: Int64 { get }
    func read(into destination: UnsafeMutablePointer<Float>, frames: Int)
    func discardBufferedSamples()
    func stop()
}

/// Preallocated interleaved stereo ring. The realtime callback never waits for a consumer or allocates.
final class StereoAudioRing: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let lock = NSLock()
    private var head = 0, count = 0
    private var received: Int64 = 0, dropped: Int64 = 0
    init(capacityFrames: Int) {
        capacity = max(1, capacityFrames); storage = .allocate(capacity: capacity * 2)
        storage.initialize(repeating: 0, count: capacity * 2)
    }
    deinit { storage.deallocate() }
    var statistics: (received: Int64, dropped: Int64, buffered: Int) { lock.lock(); defer { lock.unlock() }; return (received, dropped, count) }
    func clear() { lock.lock(); head = 0; count = 0; lock.unlock() }
    func push(left: UnsafePointer<Float>, right: UnsafePointer<Float>, stride: Int, frames: Int) {
        guard lock.try() else { return }
        defer { lock.unlock() }
        received += Int64(frames)
        for i in 0..<frames {
            if count == capacity { head = (head + 1) % capacity; count -= 1; dropped += 1 }
            let position = (head + count) % capacity
            storage[position * 2] = left[i * stride]; storage[position * 2 + 1] = right[i * stride]
            count += 1
        }
    }
    func read(into destination: UnsafeMutablePointer<Float>, frames: Int) {
        lock.lock(); defer { lock.unlock() }
        let available = min(frames, count)
        for i in 0..<available {
            let position = (head + i) % capacity
            destination[i * 2] = storage[position * 2]; destination[i * 2 + 1] = storage[position * 2 + 1]
        }
        if available < frames { destination.advanced(by: available * 2).update(repeating: 0, count: (frames - available) * 2) }
        head = (head + available) % capacity; count -= available
    }
}

/// Public Core Audio process tap. Private, temporary tap-only device; never changes the default output or captures a microphone.
@available(macOS 14.2, *)
public final class SystemAudioSource: AudioSamplesSource {
    private var tap: AudioObjectID = 0, device: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var ring: StereoAudioRing?
    public private(set) var sampleRate: Double = 48_000
    public var capturedFrames: Int64 { ring?.statistics.received ?? 0 }
    public var droppedFrames: Int64 { ring?.statistics.dropped ?? 0 }
    public init() {}
    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw MirrorError("Áudio do sistema: \(step) (\(status)). Autorize MacMirror para gravar o áudio do sistema nos Ajustes de Privacidade. É possível desmarcar o áudio para transmitir somente a imagem.") }
    }
    public func start() throws {
        do {
            var ownProcess: AudioObjectID = 0, ownPID = getpid()
            var processAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &processAddress, UInt32(MemoryLayout<pid_t>.size), &ownPID, &size, &ownProcess)
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess == 0 ? [] : [ownProcess])
            description.name = "MacMirror · Áudio do sistema"; description.isPrivate = true
            // Core Audio suppresses local playback only while this tap is being read.
            // Stopping/destroying the tap restores playback without changing system volume/output.
            description.muteBehavior = .mutedWhenTapped
            try check(AudioHardwareCreateProcessTap(description, &tap), "não foi possível criar a captura")
            var format = AudioStreamBasicDescription()
            var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &size, &format), "não foi possível consultar o formato")
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32, format.mChannelsPerFrame == 2, (8_000...192_000).contains(format.mSampleRate) else {
                throw MirrorError("O dispositivo de saída não oferece o formato estéreo Float32 necessário para capturar áudio.")
            }
            sampleRate = format.mSampleRate; ring = StereoAudioRing(capacityFrames: Int(sampleRate / 4))
            // No physical input subdevice is attached: no microphone stream can enter this aggregate.
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MacMirror Audio (temporário)",
                kAudioAggregateDeviceUIDKey: "local.macmirror.audio.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "não foi possível preparar o dispositivo temporário")
            let callback: AudioDeviceIOProc = { _, _, input, _, output, _, context in
                guard let context else { return noErr }
                let source = Unmanaged<SystemAudioSource>.fromOpaque(context).takeUnretainedValue()
                source.receive(input)
                // Tap-only devices normally have no output buffers; explicitly silence any provided buffer.
                for buffer in UnsafeMutableAudioBufferListPointer(output) { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
                return noErr
            }
            try check(AudioDeviceCreateIOProcID(device, callback, Unmanaged.passUnretained(self).toOpaque(), &ioProc), "não foi possível registrar a leitura")
            try check(AudioDeviceStart(device, ioProc), "não foi possível iniciar a captura")
        } catch { stop(); throw error }
    }
    private func receive(_ pointer: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: pointer))
        guard let first = buffers.first, let data = first.mData else { return }
        let left = data.assumingMemoryBound(to: Float.self)
        if first.mNumberChannels >= 2 {
            ring?.push(left: left, right: left.advanced(by: 1), stride: Int(first.mNumberChannels), frames: Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels)))
        } else if buffers.count >= 2, let right = buffers[1].mData {
            ring?.push(left: left, right: right.assumingMemoryBound(to: Float.self), stride: 1, frames: min(Int(first.mDataByteSize), Int(buffers[1].mDataByteSize)) / MemoryLayout<Float>.size)
        }
    }
    public func read(into destination: UnsafeMutablePointer<Float>, frames: Int) { ring?.read(into: destination, frames: frames) }
    public func discardBufferedSamples() { ring?.clear() }
    public func stop() {
        if device != 0 {
            if let ioProc { AudioDeviceStop(device, ioProc); AudioDeviceDestroyIOProcID(device, ioProc) }
            AudioHardwareDestroyAggregateDevice(device)
        }
        ioProc = nil; device = 0
        if tap != 0 { AudioHardwareDestroyProcessTap(tap) }; tap = 0; ring = nil
    }
    deinit { stop() }
}

/// Used only by explicit integration tests. It is never played through the Mac's speakers.
public final class SyntheticAudioSource: AudioSamplesSource {
    public let sampleRate: Double
    private let lock = NSLock()
    private var generated: Int64 = 0
    public var capturedFrames: Int64 { lock.lock(); defer { lock.unlock() }; return generated }
    public var droppedFrames: Int64 { 0 }
    private var phase = 0.0
    public init(sampleRate: Double = 48_000) { self.sampleRate = sampleRate }
    public func read(into destination: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0..<frames {
            let value = Float(sin(phase) * 0.15); phase += 2 * .pi * 440 / sampleRate
            if phase >= 2 * .pi { phase -= 2 * .pi }
            destination[i * 2] = value; destination[i * 2 + 1] = value
        }
        lock.lock(); generated += Int64(frames); lock.unlock()
    }
    public func discardBufferedSamples() {}
    public func stop() {}
}

/// Fixed 20 ms stereo clock. Silence on input underflow keeps the stream valid when no application is producing sound.
public final class AudioPump: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacMirror.audio.clock", qos: .userInitiated)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private let source: AudioSamplesSource
    private let input: AVAudioPCMBuffer, output: AVAudioPCMBuffer
    private let converter: AVAudioConverter?
    private var level = -120.0
    public var onFailure: ((Error) -> Void)?
    public init(source: AudioSamplesSource) throws {
        self.source = source
        let native = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate, channels: 2, interleaved: true)!
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        guard let input = AVAudioPCMBuffer(pcmFormat: native, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 960) else { throw MirrorError("Não foi possível preparar os buffers de áudio.") }
        self.input = input; self.output = output
        converter = abs(source.sampleRate - 48_000) < 1 ? nil : AVAudioConverter(from: native, to: target)
        if source.sampleRate != 48_000 && converter == nil { throw MirrorError("Não foi possível converter o áudio para 48 kHz.") }
        converter?.primeMethod = .none
    }
    public var dbFS: Double { lock.lock(); defer { lock.unlock() }; return level }
    private func updateLevel(_ value: Double) { lock.lock(); level = value; lock.unlock() }
    public func start(write: @escaping (Data) throws -> Void) {
        source.discardBufferedSamples()
        let timer = DispatchSource.makeTimerSource(queue: queue); self.timer = timer
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, let timer = self.timer else { return }
            let ticks = max(1, Int(timer.data))
            if ticks > 50 { self.onFailure?(MirrorError("O áudio ficou mais de um segundo atrasado. Reduza a carga do Mac e reinicie.")); return }
            do { for _ in 0..<ticks { try write(self.chunk()) } } catch { self.onFailure?(error) }
        }
        timer.resume()
    }
    func chunk() throws -> Data {
        let samples: UnsafeMutablePointer<Float>
        if let converter {
            output.frameLength = 0
            var error: NSError?
            // Supply the converter's requested amount, not a fixed block followed by noDataNow.
            // That preserves its filter history and avoids padding silence at every 44.1 kHz boundary.
            let status = converter.convert(to: output, error: &error) { requested, state in
                let frames = min(requested, self.input.frameCapacity)
                guard frames > 0 else { state.pointee = .noDataNow; return nil }
                self.input.frameLength = frames
                self.source.read(into: self.input.floatChannelData![0], frames: Int(frames))
                state.pointee = .haveData; return self.input
            }
            if status == .error { throw error ?? MirrorError("Falha ao converter áudio.") as NSError }
            samples = output.floatChannelData![0]
            if output.frameLength < 960 { samples.advanced(by: Int(output.frameLength) * 2).update(repeating: 0, count: (960 - Int(output.frameLength)) * 2) }
        } else {
            input.frameLength = 960
            source.read(into: input.floatChannelData![0], frames: 960)
            samples = input.floatChannelData![0]
        }
        var energy = 0.0
        for i in 0..<1920 { let x = Double(samples[i]); energy += x * x }
        updateLevel(max(-120, 10 * log10(max(1e-12, energy / 1920))))
        return Data(bytes: samples, count: 1920 * MemoryLayout<Float>.size)
    }
    public func stop() async {
        await withCheckedContinuation { continuation in queue.async { [self] in timer?.cancel(); timer = nil; continuation.resume() } }
        source.stop()
    }
}
