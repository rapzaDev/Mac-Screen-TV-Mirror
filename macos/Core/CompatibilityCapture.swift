import Foundation
import AVFoundation
import CoreImage
import CoreGraphics
import CoreMedia
import OSLog

/// Alternative public macOS capture API. No recording output, private API, or permission bypass.
public final class CompatibilityScreenSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "MacMirror.compatibility.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    private var renderer: LetterboxRenderer?
    private var observer: NSObjectProtocol?
    public var onFailure: ((Error) -> Void)?
    public var backendName: String { "AVFoundation · compatibilidade" }
    public func start(displayID: CGDirectDisplayID, quality: Quality) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard let input = AVCaptureScreenInput(displayID: displayID) else { throw MirrorError("Monitor indisponível para captura de compatibilidade.") }
                    input.minFrameDuration = CMTime(value: 1, timescale: Int32(quality.fps)); input.capturesCursor = true
                    let bounds = CGDisplayBounds(displayID)
                    input.scaleFactor = min(1, min(CGFloat(quality.width) / bounds.width, CGFloat(quality.height) / bounds.height))
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    output.setSampleBufferDelegate(self, queue: queue)
                    session.beginConfiguration()
                    guard session.canAddInput(input), session.canAddOutput(output) else { session.commitConfiguration(); throw MirrorError("AVFoundation não aceita captura deste monitor.") }
                    session.addInput(input); session.addOutput(output); session.commitConfiguration()
                    renderer = try LetterboxRenderer(quality: quality)
                    observer = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] notification in
                        self?.onFailure?((notification.userInfo?[AVCaptureSessionErrorKey] as? Error) ?? MirrorError("A captura AVFoundation foi interrompida."))
                    }
                    session.startRunning()
                    guard session.isRunning else { throw MirrorError("AVFoundation não iniciou. Verifique a permissão de tela.") }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func latest() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return frame }
    private func clearFrame() { lock.lock(); frame = nil; lock.unlock() }
    public func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
                session.stopRunning()
                for output in session.outputs { (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil); session.removeOutput(output) }
                for input in session.inputs { session.removeInput(input) }
                clearFrame(); renderer = nil; continuation.resume()
            }
        }
    }
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let input = sampleBuffer.imageBuffer, let pixel = renderer?.render(input) else { return }
        lock.lock(); frame = pixel; lock.unlock()
    }

}

/// Keeps the capture choice separate from encoding and transport. SCK remains preferred when resources permit.
public final class AdaptiveScreenSource: FrameSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: FrameSource?
    private var active = false
    private var fallbackStarted = false
    private var displayID: CGDirectDisplayID = 0
    private var quality: Quality = .balanced
    private let logger = Logger(subsystem: "local.macmirror.app", category: "capture")
    public var onFailure: ((Error) -> Void)?
    public var onRecovering: (() -> Void)?
    public var backendName: String { lock.lock(); defer { lock.unlock() }; return current?.backendName ?? "Preparando captura" }
    public func latest() -> CVPixelBuffer? { lock.lock(); let source = current; lock.unlock(); return source?.latest() }
    private func getCurrent() -> FrameSource? { lock.lock(); defer { lock.unlock() }; return current }
    private func claimRecovery() -> Bool { lock.lock(); defer { lock.unlock() }; guard active, !fallbackStarted else { return false }; fallbackStarted = true; return true }
    private func markFallback() { lock.lock(); fallbackStarted = true; lock.unlock() }
    private func set(_ source: FrameSource?) { lock.lock(); current = source; lock.unlock() }
    private func isActive() -> Bool { lock.lock(); defer { lock.unlock() }; return active }
    private func markActive(_ value: Bool) { lock.lock(); active = value; lock.unlock() }
    public func start(displayID: CGDirectDisplayID, quality: Quality, compatibility: Bool = false) async throws {
        self.displayID = displayID; self.quality = quality; markActive(true)
        let free = ((try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())[.systemFreeSize]) as? NSNumber)?.int64Value ?? Int64.max
        // Observed replayd urgency purges on this Mac at 97% full. This is a routing heuristic, not a claimed OS threshold.
        if compatibility || free < 10_000_000_000 {
            logger.info("backend=AVFoundation reason=compatibility_or_low_disk")
            try await startCompatibility(); return
        }
        let primary = ScreenSource(); set(primary)
        primary.onFailure = { [weak self] error in
            guard let self else { return }
            let code = (error as NSError).code
            if code == -3821 && self.isActive() {
                Task { await self.recoverFromSystemInterruption(error) }
            } else { self.onFailure?(error) }
        }
        do { try await primary.start(displayID: displayID, quality: quality) }
        catch { await primary.stop(); throw error }
        if !isActive() { await primary.stop() }
    }
    private func startCompatibility() async throws {
        guard isActive() else { return }
        markFallback()
        let fallback = CompatibilityScreenSource(); fallback.onFailure = { [weak self] error in self?.onFailure?(error) }
        set(fallback)
        do { try await fallback.start(displayID: displayID, quality: quality) }
        catch { await fallback.stop(); throw error }
        if !isActive() { await fallback.stop() }
    }
    private func recoverFromSystemInterruption(_ error: Error) async {
        guard CGPreflightScreenCaptureAccess(), claimRecovery() else { if isActive() { onFailure?(error) }; return }
        onRecovering?(); logger.info("ScreenCaptureKit stopped by system; switching to public AVFoundation capture")
        let old = getCurrent()
        await old?.stop()
        do { try await startCompatibility() } catch { onFailure?(error) }
    }
    public func stop() async {
        markActive(false)
        let old = getCurrent(); set(nil)
        await old?.stop()
    }
}

/// Serial, bounded conversion to a fixed canvas; black bars preserve source aspect ratio.
final class LetterboxRenderer {
    private var pool: CVPixelBufferPool?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let width: Int, height: Int
    init(quality: Quality) throws {
        width = quality.width; height = quality.height
        let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { throw MirrorError("Não foi possível criar buffers de conversão de vídeo.") }
    }
    func render(_ input: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool else { return nil }; var pixel: CVPixelBuffer?
        let limit = [kCVPixelBufferPoolAllocationThresholdKey as String: 5] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limit, &pixel) == kCVReturnSuccess, let pixel else { return nil }
        let image = CIImage(cvPixelBuffer: input)
        let w = CGFloat(width), h = CGFloat(height), scale = min(w / image.extent.width, h / image.extent.height)
        let transform = CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: (w - image.extent.width * scale) / 2, y: (h - image.extent.height * scale) / 2))
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: rect)
        context.render(image.transformed(by: transform).composited(over: black), to: pixel, bounds: rect, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return pixel
    }
}
