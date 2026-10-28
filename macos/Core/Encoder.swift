import Foundation
import VideoToolbox
import CoreMedia

public protocol VideoEncoding: AnyObject {
    func encode(_ frame: CVPixelBuffer, index: Int64) throws
    func stop()
}

public final class H264Encoder: VideoEncoding {
    private var session: VTCompressionSession?
    private let quality: Quality
    private let lock = NSLock()
    private var pending = 0
    public private(set) var hardware = false
    public var onPacket: ((Data) throws -> Void)?
    public var onFailure: ((Error) -> Void)?
    public var onDrop: (() -> Void)?
    public init(quality: Quality, tuning: StreamTuning = .stable) throws {
        self.quality = quality
        let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true] as CFDictionary
        let callback: VTCompressionOutputCallback = { context, _, status, flags, sample in
            guard let context else { return }
            let encoder = Unmanaged<H264Encoder>.fromOpaque(context).takeUnretainedValue()
            defer { encoder.lock.lock(); encoder.pending -= 1; encoder.lock.unlock() }
            guard status == noErr else { encoder.onFailure?(MirrorError("VideoToolbox: \(status)")); return }
            guard !flags.contains(.frameDropped), let sample, CMSampleBufferDataIsReady(sample) else { encoder.onDrop?(); return }
            do { try encoder.onPacket?(H264Encoder.annexB(sample)) } catch { encoder.onFailure?(error) }
        }
        try check(VTCompressionSessionCreate(allocator: nil, width: Int32(quality.width), height: Int32(quality.height), codecType: kCMVideoCodecType_H264, encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: callback, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &session))
        do {
            try property(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
            try property(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
            try property(kVTCompressionPropertyKey_ProfileLevel, quality == .quality ? kVTProfileLevel_H264_Main_4_0 : kVTProfileLevel_H264_Baseline_3_1)
            try property(kVTCompressionPropertyKey_AverageBitRate, quality.bitrate as CFNumber)
            try property(kVTCompressionPropertyKey_ExpectedFrameRate, quality.fps as CFNumber)
            try property(kVTCompressionPropertyKey_MaxKeyFrameInterval, Int(Double(quality.fps) * tuning.keyframeSeconds) as CFNumber)
            try property(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, tuning.keyframeSeconds as CFNumber)
            try check(VTCompressionSessionPrepareToEncodeFrames(session!))
            var using: Unmanaged<CFBoolean>?
            VTSessionCopyProperty(session!, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: &using)
            hardware = using?.takeRetainedValue() == kCFBooleanTrue
        } catch { stop(); throw error }
    }
    private func check(_ status: OSStatus) throws { if status != noErr { throw MirrorError("Não foi possível configurar o encoder H.264 (\(status)).") } }
    private func property(_ key: CFString, _ value: CFTypeRef) throws { try check(VTSessionSetProperty(session!, key: key, value: value)) }
    public func encode(_ frame: CVPixelBuffer, index: Int64) throws {
        guard let session else { throw MirrorError("Encoder encerrado.") }
        lock.lock()
        if pending >= 3 { lock.unlock(); onDrop?(); return }
        pending += 1; lock.unlock()
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: frame, presentationTimeStamp: CMTime(value: index, timescale: Int32(quality.fps)), duration: CMTime(value: 1, timescale: Int32(quality.fps)), frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
        if status != noErr { lock.lock(); pending -= 1; lock.unlock(); try check(status) }
    }
    public func stop() {
        if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid); VTCompressionSessionInvalidate(session) }
        session = nil
    }
    deinit { stop() }
    public static func annexB(_ sample: CMSampleBuffer) throws -> Data {
        guard let format = sample.formatDescription, let block = sample.dataBuffer else { throw MirrorError("Frame H.264 incompleto.") }
        var result = Data(), count = 0, headerLength: Int32 = 0
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        let start: [UInt8] = [0, 0, 0, 1]
        if key {
            var pointer: UnsafePointer<UInt8>?, size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
            guard status == noErr else { throw MirrorError("SPS H.264 inválido.") }
            for index in 0..<count {
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer else { throw MirrorError("Parâmetro H.264 inválido.") }
                result.append(contentsOf: start); result.append(pointer, count: size)
            }
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &headerLength)
        }
        guard headerLength == 4 else { throw MirrorError("Comprimento AVCC não suportado.") }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == noErr else { throw MirrorError("Falha lendo frame H.264.") }
        var offset = 0
        while offset + 4 <= length {
            let size = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }; offset += 4
            guard size > 0, size <= length - offset else { throw MirrorError("NAL H.264 corrompido.") }
            result.append(contentsOf: start); result.append(contentsOf: bytes[offset..<offset + size]); offset += size
        }
        guard offset == length else { throw MirrorError("Frame H.264 truncado.") }
        return result
    }
}
