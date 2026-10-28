import Foundation
import OSLog
import ScreenCaptureKit
import CoreMedia

public final class VideoPump: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacMirror.encoder.input", qos: .userInteractive)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var encoder: H264Encoder?
    private var source: FrameSource?
    private var muxer: HLSMuxer?
    private var audioPump: AudioPump?
    private var audioSource: AudioSamplesSource?
    private var metrics = StreamMetrics()
    private var lastFrames = 0, lastBytes = 0
    private var lastTime = Date()
    private var started = Date()
    private var targetFPS = 30
    private var stopped = false
    public var onFailure: ((Error) -> Void)?
    public func start(source: FrameSource, quality: Quality, directory: URL, server: LocalHTTPServer, audioSource: AudioSamplesSource? = nil, tuning: StreamTuning = .stable) throws {
        self.source = source; started = Date(); lastTime = started; targetFPS = quality.fps
        let muxer = try HLSMuxer(quality: quality, directory: directory, audioEnabled: audioSource != nil, tuning: tuning); self.muxer = muxer
        muxer.onTransportBytes = { [weak server] data in server?.broadcast(data) }
        muxer.onFailure = { [weak self] error in self?.onFailure?(error) }
        let encoder = try H264Encoder(quality: quality, tuning: tuning); self.encoder = encoder
        metrics.hardware = encoder.hardware
        encoder.onPacket = { [weak self, weak muxer] packet in
            try muxer?.write(packet)
            self?.lock.lock(); self?.metrics.frames += 1; self?.metrics.bytes += packet.count; self?.lock.unlock()
        }
        encoder.onDrop = { [weak self] in self?.lock.lock(); self?.metrics.dropped += 1; self?.lock.unlock() }
        encoder.onFailure = { [weak self] error in self?.onFailure?(error) }
        self.audioSource = audioSource
        if let audioSource {
            let audio = try AudioPump(source: audioSource); audioPump = audio
            audio.onFailure = { [weak self] error in self?.onFailure?(error) }
        }
        var index: Int64 = 0
        let timer = DispatchSource.makeTimerSource(queue: queue); self.timer = timer
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / quality.fps), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self, weak source, weak encoder] in
            guard let self, !self.stopped else { return }
            if let frame = source?.latest() {
                let due = min(3, max(1, Int(self.timer?.data ?? 1)))
                for _ in 0..<due {
                    do { try encoder?.encode(frame, index: index) } catch { self.onFailure?(error) }
                    index += 1
                }
            }
        }
        timer.resume()
        audioPump?.start { [weak muxer] pcm in try muxer?.writeAudio(pcm) }
    }
    public var timingLag: Double { Date().timeIntervalSince(started) - Double(snapshot().frames) / Double(targetFPS) }
    public var diagnostics: String { muxer?.diagnostics ?? "" }
    public func snapshot() -> StreamMetrics {
        lock.lock(); defer { lock.unlock() }
        let now = Date(), elapsed = now.timeIntervalSince(lastTime)
        if elapsed >= 0.8 {
            metrics.fps = Double(metrics.frames - lastFrames) / elapsed
            metrics.mbps = Double(metrics.bytes - lastBytes) * 8 / elapsed / 1_000_000
            lastTime = now; lastFrames = metrics.frames; lastBytes = metrics.bytes
        }
        metrics.captureBackend = source?.backendName ?? ""
        metrics.audioEnabled = audioPump != nil
        metrics.audioDBFS = audioPump?.dbFS ?? -120
        metrics.audioCapturedFrames = audioSource?.capturedFrames ?? 0
        metrics.audioDroppedFrames = audioSource?.droppedFrames ?? 0
        return metrics
    }
    public func stop() async {
        await audioPump?.stop(); audioPump = nil; audioSource = nil
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                stopped = true; timer?.cancel(); timer = nil
                encoder?.stop(); encoder = nil
                muxer?.stop(); muxer = nil
                continuation.resume()
            }
        }
        await source?.stop(); source = nil
    }
}

@MainActor
public final class MirrorSession: ObservableObject {
    private let logger = Logger(subsystem: "local.macmirror.app", category: "session")
    @Published public private(set) var state: SessionState = .idle {
        didSet { if oldValue != state { logger.info("state=\(self.state.rawValue, privacy: .public)") } }
    }
    @Published public private(set) var message = "Selecione a tela e inicie quando estiver pronto."
    @Published public private(set) var metrics = StreamMetrics()
    @Published public private(set) var receiverURL = ""
    @Published public private(set) var sessionCode = ""
    @Published public private(set) var streamURL = ""
    @Published public private(set) var transportStatus = ""
    @Published public private(set) var directory: URL?
    public private(set) var server: LocalHTTPServer?
    private var pump: VideoPump?
    private var source: FrameSource?
    private var audioSource: AudioSamplesSource?
    private var monitor: Task<Void, Never>?
    private var target: TVDevice?
    private var network: LocalNetwork?
    private var generation = UUID()
    private var stopping = false
    public init() {}
    public func start(displayID: CGDirectDisplayID, quality: Quality, device: TVDevice?, webRoot: URL, synthetic: Bool = false, autoPlay: Bool = true, hlsDLNA: Bool = false, qualityConfirmed: Bool = false, token: String? = nil, audioEnabled: Bool = false, syntheticAudio: Bool = false, tuning: StreamTuning = .stable, port: UInt16 = 8787) async {
        guard !state.active, !stopping else { return }
        state = .preparing; message = "Preparando captura, H.264 e servidor local…"; metrics = .init(); transportStatus = ""; receiverURL = ""; streamURL = ""; sessionCode = ""
        let id = UUID(); generation = id
        do {
            guard quality != .quality || qualityConfirmed else { throw MirrorError("Confirme o suporte do receptor antes de usar 1080p.") }
            let network = try LocalNetwork.current(); self.network = network
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacMirror-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            self.directory = directory
            let server = LocalHTTPServer(network: network, port: port, directory: directory, webRoot: webRoot, token: token, tuning: tuning); self.server = server
            let diagnostics = LiveDiagnostics()
            try await server.start { diagnostics.read() }
            try ensureCurrent(id)
            let source: FrameSource
            if synthetic { source = try SyntheticSource(quality: quality) }
            else {
                let screen = AdaptiveScreenSource()
                screen.onFailure = { [weak self] error in Task { @MainActor in await self?.fail(error, generation: id) } }
                screen.onRecovering = { [weak self] in Task { @MainActor in
                    guard let self, self.generation == id else { return }
                    self.state = .reconnecting; self.message = "Recuperando a captura pelo modo de compatibilidade…"
                } }
                self.source = screen
                do { try await screen.start(displayID: displayID, quality: quality) }
                catch { await screen.stop(); throw error }
                guard generation == id, !stopping else { await screen.stop(); return }
                source = screen
            }
            self.source = source
            try ensureCurrent(id)
            if audioEnabled {
                if syntheticAudio { audioSource = SyntheticAudioSource() }
                else if #available(macOS 14.2, *) {
                    let audio = SystemAudioSource(); audioSource = audio
                    try audio.start()
                } else { throw MirrorError("Áudio do sistema exige macOS 14.2 ou posterior. Desmarque o áudio para transmitir somente a imagem.") }
            }
            try ensureCurrent(id)
            let pump = VideoPump(); self.pump = pump
            pump.onFailure = { [weak self] error in Task { @MainActor in await self?.fail(error, generation: id) } }
            try pump.start(source: source, quality: quality, directory: directory, server: server, audioSource: audioSource, tuning: tuning)
            // Do not announce streaming until a real live playlist exists.
            var ready = false
            for _ in 0..<150 {
                try await Task.sleep(nanoseconds: 100_000_000); try ensureCurrent(id)
                if let playlist = try? String(contentsOf: directory.appendingPathComponent("live.m3u8"), encoding: .utf8), playlist.contains("#EXTINF") { ready = true; break }
            }
            guard ready else { throw MirrorError("Nenhum segmento HLS foi produzido em 15 segundos. Frames: \(pump.snapshot().frames). \(pump.diagnostics)") }
            receiverURL = server.receiverURL; sessionCode = server.token; streamURL = server.streamURL
            state = .streaming; message = synthetic ? "TESTE SINTÉTICO · Não é captura de tela." : "Captura ativa. Abra o receptor ou use a conexão DLNA."
            target = autoPlay ? device : nil
            if let device, autoPlay {
                do {
                    try await DLNA.play(device: device, url: hlsDLNA ? server.streamURL : server.transportURL, hls: hlsDLNA, stillActive: { [weak self] in await MainActor.run { self?.generation == id } })
                    try ensureCurrent(id)
                    transportStatus = "Comando DLNA enviado. Confirme a imagem na TV."
                } catch { transportStatus = error.localizedDescription + " Abra o receptor no navegador da TV." }
            }
            try ensureCurrent(id)
            monitor = Task { [weak self] in
                var emptyTicks = 0, lastFrames = 0
                var nextTVCheck = Date().addingTimeInterval(5)
                var reconnectAttempts = 0
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled, let self, self.generation == id, self.state.active else { return }
                    let snapshot = pump.snapshot(); self.metrics = snapshot; self.metrics.clients = server.snapshot().clients
                    diagnostics.update(metrics: self.metrics, state: self.state)
                    emptyTicks = snapshot.frames == lastFrames ? emptyTicks + 1 : 0; lastFrames = snapshot.frames
                    if pump.timingLag > 2.5 { await self.fail(MirrorError("A codificação não está acompanhando o tempo real. Use o preset Econômico e reduza a carga do Mac."), generation: id); return }
                    if emptyTicks > 5 { await self.fail(MirrorError("Captura sem frames há mais de 5 segundos. Desbloqueie o Mac e reinicie a transmissão."), generation: id); return }
                    if let target = self.target, Date() >= nextTVCheck {
                        do {
                            let transport = try await DLNA.transportState(device: target)
                            guard self.generation == id, !Task.isCancelled else { return }
                            self.transportStatus = "DLNA: \(transport) · confirme a imagem na TV."
                            if transport == "STOPPED" || transport == "NO_MEDIA_PRESENT" {
                                self.state = .reconnecting
                                try await DLNA.play(device: target, url: hlsDLNA ? server.streamURL : server.transportURL, hls: hlsDLNA, stillActive: { [weak self] in await MainActor.run { self?.generation == id } })
                                reconnectAttempts += 1
                            } else if transport == "PLAYING" { reconnectAttempts = 0 }
                        } catch {
                            guard self.generation == id, !Task.isCancelled else { return }
                            reconnectAttempts += 1; self.state = .reconnecting
                            self.transportStatus = "TV sem resposta: \(error.localizedDescription). Nova tentativa em até 30 s."
                        }
                        nextTVCheck = Date().addingTimeInterval(min(30, 5 * pow(2, Double(min(3, reconnectAttempts)))))
                    }
                    if let current = try? LocalNetwork.current(), current == network {
                        self.state = .streaming
                    } else {
                        self.state = .reconnecting; self.message = "A rede mudou. Parando a captura; reinicie para obter o novo endereço."
                        await self.stop(); return
                    }
                }
            }
        } catch {
            if generation == id { await fail(error, generation: id) }
        }
    }
    private func ensureCurrent(_ id: UUID) throws { if generation != id || stopping { throw CancellationError() } }
    private func fail(_ error: Error, generation id: UUID) async {
        guard generation == id, !stopping else { return }
        logger.error("failure=\(error.localizedDescription, privacy: .public)")
        await stop()
        state = .error; message = error.localizedDescription
    }
    public func stop() async {
        guard !stopping else { return }; stopping = true; generation = UUID()
        monitor?.cancel(); monitor = nil
        // Close spectators first: pressing Stop revokes the token before draining native resources.
        server?.stop(); server = nil; receiverURL = ""; streamURL = ""; sessionCode = ""
        let pump = self.pump; self.pump = nil
        await pump?.stop()
        await source?.stop(); source = nil
        audioSource?.stop(); audioSource = nil
        if let target { await DLNA.stop(device: target) }; target = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }; directory = nil
        metrics = .init(); state = .disconnected; message = "Transmissão encerrada. Acesso revogado e segmentos temporários removidos."
        stopping = false
    }
    public func refreshTransport() async {
        if let target { transportStatus = (try? await DLNA.transportState(device: target)).map { "DLNA: \($0) · imagem ainda requer confirmação física" } ?? "A TV não respondeu ao estado DLNA." }
    }
}

/// Authenticated endpoint diagnostics. Contains counters/levels only, never pixels, PCM, or access tokens.
private final class LiveDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data("{\"live\":false,\"state\":\"preparing\"}".utf8)
    private struct Payload: Encodable { let live: Bool; let state: String; let metrics: StreamMetrics; let timestamp: Double }
    func update(metrics: StreamMetrics, state: SessionState) {
        guard let data = try? JSONEncoder().encode(Payload(live: state.active, state: state.rawValue, metrics: metrics, timestamp: Date().timeIntervalSince1970)) else { return }
        lock.lock(); value = data; lock.unlock()
    }
    func read() -> Data { lock.lock(); defer { lock.unlock() }; return value }
}
