import Foundation
import MirrorCore
import CoreGraphics
import AVFoundation
import QuartzCore

@main
struct Probe {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        func option(_ name: String) -> String? { guard let i = args.firstIndex(of: name), args.count > i + 1 else { return nil }; return args[i + 1] }
        let session = MirrorSession()
        do {
            guard !((args.contains("--screen") || args.contains("--system-audio")) && option("--export") != nil) else { throw MirrorError("Este diagnóstico não exporta tela ou áudio reais; use somente fontes sintéticas.") }
            if let address = option("--play-url"), let url = URL(string: address) {
                let asset = AVURLAsset(url: url)
                let item = AVPlayerItem(asset: asset)
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                item.add(output)
                let player = AVPlayer(playerItem: item); player.isMuted = true; player.play()
                let seconds = Int(option("--seconds") ?? "20") ?? 20
                var frames = 0, first = -1.0, last = -1.0, width = 0, height = 0
                for _ in 0..<(seconds * 30) {
                    try await Task.sleep(nanoseconds: 33_333_333)
                    if item.status == .failed { throw MirrorError("AVPlayer: \(item.error?.localizedDescription ?? "erro desconhecido")") }
                    let time = output.itemTime(forHostTime: CACurrentMediaTime())
                    if output.hasNewPixelBuffer(forItemTime: time), let pixel = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                        frames += 1; if first < 0 { first = time.seconds }; last = time.seconds
                        width = CVPixelBufferGetWidth(pixel); height = CVPixelBufferGetHeight(pixel)
                    }
                }
                player.pause(); player.replaceCurrentItem(with: nil)
                print("AVPLAYER frames=\(frames) mediaSeconds=\(last-first) resolution=\(width)x\(height)")
                guard frames >= 60, last - first > 2 else { throw MirrorError("AVPlayer não confirmou reprodução contínua.") }; return
            }
            if let path = option("--encode-file") {
                let quality = Quality.balanced, source = try SyntheticSource(quality: .balanced)
                FileManager.default.createFile(atPath: path, contents: nil)
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                let encoder = try H264Encoder(quality: quality)
                encoder.onPacket = { packet in try handle.write(contentsOf: packet) }
                encoder.onFailure = { error in print(error) }
                for i in 0..<120 { if let frame = source.latest() { try encoder.encode(frame, index: Int64(i)) }; try await Task.sleep(nanoseconds: 33_333_333) }
                encoder.stop(); try handle.close(); print("ENCODED hardware=\(encoder.hardware)"); return
            }
            let network = try LocalNetwork.current()
            if args.contains("--discover") {
                let devices = try await DeviceDiscovery.discover(network: network)
                for d in devices { print("\(d.name) | \(d.model) | \(d.ip) | \(d.capabilityLabel)") }; return
            }
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("receiver/web")
            let device: TVDevice?
            if let ip = option("--tv") { device = try await DeviceDiscovery.manual(ip: ip, network: network) } else { device = nil }
            let quality = Quality(rawValue: option("--quality") ?? "balanced") ?? .balanced
            await session.start(displayID: CGMainDisplayID(), quality: quality, device: device, webRoot: root, synthetic: !args.contains("--screen"), hlsDLNA: args.contains("--hls-dlna"), qualityConfirmed: args.contains("--allow-1080"), token: option("--token"), audioEnabled: args.contains("--audio-tone") || args.contains("--system-audio"), syntheticAudio: args.contains("--audio-tone"), tuning: args.contains("--responsive") ? .responsive : .stable, port: UInt16(option("--port") ?? "8787") ?? 8787)
            guard session.state == .streaming else { throw MirrorError(session.message) }
            print("INITIAL_DLNA \(session.transportStatus)")
            print("READY \(session.receiverURL)")
            print("HLS \(session.streamURL)")
            print("TEMP \(session.directory!.path)")
            fflush(stdout)
            let seconds = Int(option("--seconds") ?? "30") ?? 30
            for tick in 0..<seconds {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                if tick % 5 == 0 {
                    await session.refreshTransport()
                    let m = session.metrics
                    print(String(format: "t=%d frames=%d fps=%.2f H264Mbps=%.3f hw=%@ clients=%d dropped=%d audioDB=%.1f %@", tick, m.frames, m.fps, m.mbps, m.hardware.description, m.clients, m.dropped, m.audioDBFS, session.transportStatus)); fflush(stdout)
                }
                if session.state == .error { throw MirrorError(session.message) }
            }
            if let server = session.server { print("HTTP_STATS \(server.snapshot())") }
            if let path = option("--export"), let directory = session.directory {
                let dest = URL(fileURLWithPath: path)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where ["ts", "m3u8"].contains(file.pathExtension) {
                    try FileManager.default.copyItem(at: file, to: dest.appendingPathComponent(file.lastPathComponent))
                }
            }
            await session.stop(); print("STOPPED \(session.state.rawValue)")
        } catch { await session.stop(); fputs("ERROR \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
