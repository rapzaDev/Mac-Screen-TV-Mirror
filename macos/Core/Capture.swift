import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics

public struct DisplayChoice: Identifiable, Equatable {
    public let id: CGDirectDisplayID
    public let width: Int
    public let height: Int
    public var label: String { "\(id == CGMainDisplayID() ? "Tela principal" : "Monitor \(id)") · \(width)×\(height)" }
}

public protocol FrameSource: AnyObject {
    var backendName: String { get }
    func latest() -> CVPixelBuffer?
    func stop() async
}

public extension FrameSource { var backendName: String { "ScreenCaptureKit" } }

public final class ScreenSource: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    private let callbackQueue = DispatchQueue(label: "MacMirror.capture", qos: .userInteractive)
    public var onFailure: ((Error) -> Void)?
    public static func displays() async throws -> [DisplayChoice] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays.map { .init(id: $0.displayID, width: $0.width, height: $0.height) }.sorted { $0.id < $1.id }
    }
    public func start(displayID: CGDirectDisplayID, quality: Quality) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw MirrorError("O monitor foi desconectado. Selecione outro monitor.") }
        let config = SCStreamConfiguration()
        config.width = quality.width; config.height = quality.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(quality.fps))
        config.queueDepth = 3; config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true; config.capturesAudio = false
        config.scalesToFit = true; config.preservesAspectRatio = true
        config.backgroundColor = CGColor.black
        config.colorSpaceName = CGColorSpace.sRGB
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: callbackQueue)
        stream = newStream
        do { try await newStream.startCapture() } catch { stream = nil; throw error }
    }
    public func latest() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return frame }
    private func clear() { lock.lock(); frame = nil; lock.unlock() }
    public func stop() async {
        let old = stream; stream = nil
        try? await old?.stopCapture()
        clear()
    }
    public func stream(_ stream: SCStream, didStopWithError error: Error) { clear(); onFailure?(error) }
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let buffer = sampleBuffer.imageBuffer else { return }
        lock.lock(); frame = buffer; lock.unlock()
    }
}

/// Animated color bars with a moving white square. This source is used only by explicit integration tests.
public final class SyntheticSource: FrameSource {
    public var backendName: String { "Teste sintético" }
    private let width: Int, height: Int
    private var tick = 0
    private var pool: CVPixelBufferPool?
    public init(quality: Quality) throws {
        width = quality.width; height = quality.height
        let attrs: [String: Any] = [kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess else { throw MirrorError("Falha no pool de frames de teste.") }
    }
    public func latest() -> CVPixelBuffer? {
        guard let pool else { return nil }; var output: CVPixelBuffer?
        let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: 5] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux, &output) == kCVReturnSuccess, let buffer = output else { return nil }
        CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer) / 4, p = base.assumingMemoryBound(to: UInt32.self)
        let colors: [UInt32] = [0xffffffff, 0xffffff00, 0xff00ffff, 0xff00ff00, 0xffff00ff, 0xffff0000, 0xff0000ff, 0xff101010]
        let xPos = (tick * 8) % max(1, width - 80); tick += 1
        var row = [UInt32](repeating: 0, count: width)
        for x in 0..<width { row[x] = colors[min(7, x * 8 / width)] }
        row.withUnsafeBytes { bytes in
            for y in 0..<height { memcpy(p.advanced(by: y * stride), bytes.baseAddress!, width * 4) }
        }
        for y in (height / 2)..<min(height, height / 2 + 80) { for x in xPos..<min(width, xPos + 80) { p[y * stride + x] = 0xffffffff } }
        return buffer
    }
    public func stop() async { pool = nil }
}
