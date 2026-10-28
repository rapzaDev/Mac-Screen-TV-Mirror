import Foundation
import Darwin

/// Native H.264 is copied, never re-encoded. With audio, an intermediate NUT stream carries real
/// packet timestamps into the A/V muxer, avoiding the raw-H.264 scheduler issue seen in the first build.
public final class HLSMuxer {
    private let process = Process()
    private var normalizer: Process?
    private let input = Pipe(), output = Pipe()
    private var videoBridge: Pipe?
    private let lock = NSLock(), audioLock = NSLock(), logLock = NSLock()
    private let audioQueue = DispatchQueue(label: "MacMirror.audio.pipe", qos: .userInitiated)
    private let audioQueueKey = DispatchSpecificKey<Int>()
    private var pendingAudioBytes = 0
    private var audioClosed = false
    private var stopped = false
    private var audioFD: Int32 = -1
    private var errors: [Pipe] = []
    private var logTail = Data()
    public let directory: URL
    public var onTransportBytes: ((Data) -> Void)?
    public var onFailure: ((Error) -> Void)?
    public static func executable() throws -> URL {
        let paths = [Bundle.main.resourceURL?.appendingPathComponent("ffmpeg").path,
                     ProcessInfo.processInfo.environment["MACMIRROR_FFMPEG"], "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].compactMap { $0 }
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw MirrorError("FFmpeg não encontrado. Configure MACMIRROR_FFMPEG ou instale-o conforme o README.") }
        return URL(fileURLWithPath: path)
    }
    public init(quality: Quality, directory: URL, audioEnabled: Bool = false, tuning: StreamTuning = .stable) throws {
        self.directory = directory
        audioQueue.setSpecific(key: audioQueueKey, value: 1)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let executable = try Self.executable()
        let rawInput = ["-hide_banner", "-loglevel", "warning", "-nostdin", "-fflags", "+genpts", "-probesize", "8192", "-analyzeduration", "1", "-fpsprobesize", "0", "-r", "\(quality.fps)", "-f", "h264", "-i", "pipe:0"]
        let timestamps = "h264_metadata=sample_aspect_ratio=1/1:tick_rate=\(quality.fps * 2),setts=ts=N/(\(quality.fps)*TB):duration=1/(\(quality.fps)*TB)"
        let hls = "[f=hls:hls_time=\(tuning.segmentSeconds):hls_list_size=6:hls_delete_threshold=2:hls_flags=delete_segments+independent_segments+temp_file:hls_segment_filename=seg%09d.ts]live.m3u8"
        let ts = "[f=mpegts:mpegts_flags=resend_headers+pat_pmt_at_frames:mpegts_copyts=1:pcr_period=20:pes_payload_size=0:flush_packets=1:avoid_negative_ts=make_zero]pipe:1"
        process.executableURL = executable; process.currentDirectoryURL = directory
        if audioEnabled {
            let fifo = directory.appendingPathComponent("audio.pcm.fifo").path
            guard mkfifo(fifo, 0o600) == 0 else { throw MirrorError("Não foi possível criar o canal privado de áudio.") }
            // An RDWR endpoint avoids blocking startup before FFmpeg has parsed the video header.
            audioFD = open(fifo, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            guard audioFD >= 0 else { throw MirrorError("Não foi possível abrir o canal de áudio.") }
            let bridge = Pipe(); videoBridge = bridge
            let normalizer = Process(); self.normalizer = normalizer
            normalizer.executableURL = executable; normalizer.currentDirectoryURL = directory
            normalizer.arguments = rawInput + ["-map", "0:v:0", "-c:v", "copy", "-bsf:v", timestamps, "-flush_packets", "1", "-f", "nut", "pipe:1"]
            normalizer.standardInput = input; normalizer.standardOutput = bridge
            process.standardInput = bridge
            process.arguments = ["-hide_banner", "-loglevel", "warning", "-nostdin", "-probesize", "8192", "-analyzeduration", "1", "-f", "nut", "-i", "pipe:0",
                "-thread_queue_size", "32", "-f", "f32le", "-ar", "48000", "-ac", "2", "-i", "audio.pcm.fifo",
                "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", "-c:a", "aac", "-b:a", "128k", "-threads", "2",
                "-max_interleave_delta", "100000", "-flush_packets", "1", "-f", "tee", hls + "|" + ts]
        } else {
            process.standardInput = input
            process.arguments = rawInput + ["-map", "0:v:0", "-c:v", "copy", "-bsf:v", timestamps, "-threads", "2", "-max_interleave_delta", "100000", "-flush_packets", "1", "-f", "tee", hls + "|" + ts]
        }
        configure(process)
        if let normalizer { configure(normalizer) }
        process.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.onTransportBytes?(data) }
        }
        signal(SIGPIPE, SIG_IGN)
        do {
            if let normalizer { try normalizer.run() }
            try process.run()
            try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
            if let videoBridge { try? videoBridge.fileHandleForReading.close(); try? videoBridge.fileHandleForWriting.close() }
            for pipe in errors { try? pipe.fileHandleForWriting.close() }
            let fd = input.fileHandleForWriting.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        } catch { stop(); throw error }
    }
    private func configure(_ child: Process) {
        let errorPipe = Pipe(); errors.append(errorPipe); child.standardError = errorPipe
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.logLock.lock(); self.logTail.append(data)
            if self.logTail.count > 8192 { self.logTail = self.logTail.suffix(8192) }; self.logLock.unlock()
        }
        child.terminationHandler = { [weak self] child in
            guard let self else { return }
            self.lock.lock(); let intentional = self.stopped; self.lock.unlock()
            if !intentional { self.onFailure?(MirrorError("Processo de streaming encerrou (\(child.terminationStatus)): \(self.diagnostics)")) }
        }
    }
    var processIdentifiers: [Int32] { [normalizer, process].compactMap { $0?.isRunning == true ? $0?.processIdentifier : nil } }
    var processIdentifier: Int32 { process.processIdentifier }
    public var diagnostics: String { logLock.lock(); defer { logLock.unlock() }; return String(decoding: logTail, as: UTF8.self) }
    private func writeBytes(_ packet: Data, fd: Int32) throws {
        try packet.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let deadline = Date().addingTimeInterval(2)
            while offset < raw.count {
                let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if count > 0 { offset += count; continue }
                if errno == EINTR { continue }
                if errno == EAGAIN && Date() < deadline {
                    var wait = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0); _ = poll(&wait, 1, 50); continue
                }
                throw MirrorError("Streaming sem resposta ou pipe fechado. \(diagnostics)")
            }
        }
    }
    public func write(_ packet: Data) throws {
        lock.lock(); defer { lock.unlock() }; guard !stopped else { return }
        try writeBytes(packet, fd: input.fileHandleForWriting.fileDescriptor)
    }
    public func writeAudio(_ pcm: Data) throws {
        audioLock.lock()
        guard audioFD >= 0, !audioClosed else { audioLock.unlock(); return }
        guard pendingAudioBytes + pcm.count <= 1_048_576 else { audioLock.unlock(); throw MirrorError("O canal de áudio não acompanhou o tempo real. O buffer máximo foi atingido.") }
        pendingAudioBytes += pcm.count; audioLock.unlock()
        // Keep the fixed audio sampling clock independent from FFmpeg startup/probing and pipe I/O.
        audioQueue.async { [self] in
            audioLock.lock(); let fd = audioClosed ? -1 : audioFD; audioLock.unlock()
            defer { audioLock.lock(); pendingAudioBytes -= pcm.count; audioLock.unlock() }
            guard fd >= 0 else { return }
            do { try writeBytes(pcm, fd: fd) } catch { onFailure?(error) }
        }
    }
    private func closeAudio() {
        audioLock.lock(); audioClosed = true; audioLock.unlock()
        let closeDescriptor = {
            self.audioLock.lock()
            if self.audioFD >= 0 { close(self.audioFD); self.audioFD = -1 }
            self.audioLock.unlock()
        }
        if DispatchQueue.getSpecific(key: audioQueueKey) == 1 { closeDescriptor() }
        else { audioQueue.sync(execute: closeDescriptor) }
    }
    public func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }; stopped = true
        try? input.fileHandleForWriting.close(); lock.unlock()
        closeAudio()
        for child in [normalizer, process].compactMap({ $0 }) {
            if child.isRunning {
                let deadline = Date().addingTimeInterval(0.7)
                while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if child.isRunning { child.terminate() }
                let killDeadline = Date().addingTimeInterval(0.7)
                while child.isRunning && Date() < killDeadline { Thread.sleep(forTimeInterval: 0.02) }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
            }
        }
        output.fileHandleForReading.readabilityHandler = nil
        try? output.fileHandleForReading.close()
        for pipe in errors { pipe.fileHandleForReading.readabilityHandler = nil; try? pipe.fileHandleForReading.close() }
    }
    deinit { stop() }
}
