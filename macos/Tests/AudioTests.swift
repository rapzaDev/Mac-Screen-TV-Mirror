import XCTest
import CoreGraphics
import Darwin
@testable import MirrorCore

final class AudioTests: XCTestCase {
    func testAudioRingStereoOverflowAndSilence() throws {
        let ring = StereoAudioRing(capacityFrames: 4)
        let samples: [Float] = [1,-1,2,-2,3,-3,4,-4,5,-5,6,-6]
        samples.withUnsafeBufferPointer { p in ring.push(left: p.baseAddress!, right: p.baseAddress!.advanced(by: 1), stride: 2, frames: 6) }
        XCTAssertEqual(ring.statistics.received, 6); XCTAssertEqual(ring.statistics.dropped, 2)
        var output = [Float](repeating: 99, count: 12)
        output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frames: 6) }
        XCTAssertEqual(output, [3,-3,4,-4,5,-5,6,-6,0,0,0,0])
        XCTAssertEqual(ring.statistics.buffered, 0)
    }
    func testAudioConversion44100To48000HasSignalAndFixedSize() throws {
        let source = SyntheticAudioSource(sampleRate: 44_100), pump = try AudioPump(source: source)
        var samples: [Float] = []
        for _ in 0..<12 {
            let chunk = try pump.chunk()
            XCTAssertEqual(chunk.count, 960 * 2 * 4)
            chunk.withUnsafeBytes { bytes in for frame in 0..<960 { samples.append(bytes.loadUnaligned(fromByteOffset: frame * 8, as: Float.self)) } }
        }
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
        XCTAssertGreaterThan(rms, 0.07); XCTAssertLessThan(rms, 0.13)
        // Hysteresis ignores the resampler's tiny startup ringing around digital zero.
        var armed = false, crossings = 0
        for value in samples { if value < -0.02 { armed = true }; if armed && value > 0.02 { crossings += 1; armed = false } }
        let frequency = Double(crossings) * 48_000 / Double(samples.count)
        XCTAssertEqual(frequency, 440, accuracy: 12)
        XCTAssertGreaterThan(pump.dbFS, -25)
    }
    func testAudioMuxerReleasesBothProcesses() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacMirror-test-audio-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let muxer = try HLSMuxer(quality: .balanced, directory: directory, audioEnabled: true)
        let children = muxer.processIdentifiers
        XCTAssertEqual(children.count, 2)
        // No video header is supplied, so the audio FIFO consumer cannot start yet.
        // Stopping must cancel/drain this bounded pending write without deadlocking.
        try muxer.writeAudio(Data(repeating: 0, count: 512 * 1024))
        let stoppingAt = Date()
        muxer.stop(); muxer.stop()
        XCTAssertLessThan(Date().timeIntervalSince(stoppingAt), 4)
        for pid in children { XCTAssertNotEqual(kill(pid, 0), 0) }
    }
    @MainActor func testAudioVideoLiveTransportAndResponsiveSegments() async throws {
        let session = MirrorSession()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("receiver/web")
        await session.start(displayID: CGMainDisplayID(), quality: .balanced, device: nil, webRoot: root, synthetic: true,
                            audioEnabled: true, syntheticAudio: true, tuning: .responsive, port: 18878)
        guard session.state == .streaming, let directory = session.directory, let server = session.server else { XCTFail(session.message); await session.stop(); return }
        do {
            try await Task.sleep(nanoseconds: 1_300_000_000)
            let (data, response) = try await URLSession.shared.data(from: URL(string: server.streamURL)!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let playlist = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(playlist.contains("#EXTINF:1.000000"))
            XCTAssertTrue(playlist.contains("#EXT-X-TARGETDURATION:1\n"), "AVPlayer rejects a zero target duration.")
            let name = try XCTUnwrap(playlist.split(separator: "\n").last { $0.hasSuffix(".ts") })
            let segment = directory.appendingPathComponent(String(name))
            let probe = try run("ffprobe", ["-v","error","-show_packets","-show_streams","-of","json",segment.path])
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: probe) as? [String: Any])
            let streams = try XCTUnwrap(json["streams"] as? [[String: Any]])
            let audio = try XCTUnwrap(streams.first { $0["codec_type"] as? String == "audio" })
            XCTAssertEqual(audio["codec_name"] as? String, "aac"); XCTAssertEqual(audio["sample_rate"] as? String, "48000"); XCTAssertEqual(audio["channels"] as? Int, 2)
            let packets = try XCTUnwrap(json["packets"] as? [[String: Any]])
            let video = packets.filter { $0["codec_type"] as? String == "video" }, sound = packets.filter { $0["codec_type"] as? String == "audio" }
            XCTAssertEqual(video.count, 30); XCTAssertGreaterThan(sound.count, 30)
            XCTAssertTrue((video.first?["flags"] as? String)?.contains("K") == true)
            XCTAssertTrue((video[15]["flags"] as? String)?.contains("K") == true)
            let videoPTS = video.compactMap { Double($0["pts_time"] as? String ?? "") }, audioPTS = sound.compactMap { Double($0["pts_time"] as? String ?? "") }
            for (a,b) in zip(videoPTS, videoPTS.dropFirst()) { XCTAssertGreaterThan(b, a) }
            for (a,b) in zip(audioPTS, audioPTS.dropFirst()) { XCTAssertGreaterThan(b, a) }
            XCTAssertLessThan(abs(try XCTUnwrap(videoPTS.first) - XCTUnwrap(audioPTS.first)), 0.12)
            XCTAssertLessThan(abs(try XCTUnwrap(videoPTS.last) - XCTUnwrap(audioPTS.last)), 0.12)
            let decoded = try run("ffmpeg", ["-hide_banner","-loglevel","error","-i",segment.path,"-map","0:a:0","-t","0.25","-f","f32le","pipe:1"])
            XCTAssertGreaterThan(decoded.count, 4800)
            let energy = decoded.withUnsafeBytes { bytes -> Double in
                var sum = 0.0
                for i in stride(from: 0, to: bytes.count - 3, by: 4) { let x = Double(bytes.loadUnaligned(fromByteOffset: i, as: Float.self)); sum += x * x }
                return sqrt(sum / Double(bytes.count / 4))
            }
            XCTAssertGreaterThan(energy, 0.05, "AAC precisa conter o tom real, não silêncio.")
            await session.stop()
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        } catch { await session.stop(); throw error }
    }
    private func run(_ executable: String, _ args: [String]) throws -> Data {
        let process = Process(), output = Pipe()
        process.executableURL = try HLSMuxer.executable().deletingLastPathComponent().appendingPathComponent(executable)
        process.arguments = args; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(executable) falhou")
        return data
    }
}
