import Foundation
import CoreGraphics
import Darwin

public struct MirrorError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum Quality: String, CaseIterable, Identifiable, Codable, Sendable {
    case economy, balanced, quality
    public var id: String { rawValue }
    public var label: String { switch self { case .economy: return "Econômico · 480p / 24"; case .balanced: return "Equilibrado · 720p / 30"; case .quality: return "Qualidade · 1080p / 30" } }
    public var width: Int { switch self { case .economy: return 854; case .balanced: return 1280; case .quality: return 1920 } }
    public var height: Int { switch self { case .economy: return 480; case .balanced: return 720; case .quality: return 1080 } }
    public var fps: Int { self == .economy ? 24 : 30 }
    public var bitrate: Int { switch self { case .economy: return 1_200_000; case .balanced: return 3_000_000; case .quality: return 5_000_000 } }
}

public enum StreamTuning: String, CaseIterable, Identifiable, Sendable {
    case stable, responsive
    public var id: String { rawValue }
    public var label: String { self == .responsive ? "Menor atraso" : "Mais tolerância à rede" }
    public var keyframeSeconds: Double { self == .responsive ? 0.5 : 1 }
    public var startupCacheSeconds: Double { self == .responsive ? 0.15 : 2 }
    // Keep HLS segments at one second: FFmpeg 9 rounds a 0.5 s target to zero,
    // which AVPlayer rejects. DLNA uses continuous TS and still gets 0.5 s keyframes.
    public var segmentSeconds: Double { 1 }
}

public enum SessionState: String, Codable {
    case idle = "Aguardando dispositivo", preparing = "Preparando transmissão", streaming = "Transmitindo", reconnecting = "Reconectando", disconnected = "Desconectado", error = "Erro"
    public var active: Bool { self == .preparing || self == .streaming || self == .reconnecting }
}
public struct StreamMetrics: Codable {
    public var frames = 0
    public var bytes = 0
    public var dropped = 0
    public var fps = 0.0
    public var mbps = 0.0
    public var hardware = false
    public var clients = 0
    public var captureBackend = ""
    public var audioEnabled = false
    public var audioDBFS = -120.0
    public var audioCapturedFrames: Int64 = 0
    public var audioDroppedFrames: Int64 = 0
    public init() {}
}

public struct LocalNetwork: Equatable {
    public let address: String
    public let mask: String
    public let interface: String
    public static func current() throws -> LocalNetwork {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { throw MirrorError("Não foi possível consultar a rede.") }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        var networks: [LocalNetwork] = []
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let addr = item.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), let netmask = item.pointee.ifa_netmask else { continue }
            let name = String(cString: item.pointee.ifa_name)
            guard name.hasPrefix("en"), item.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            func ip(_ ptr: UnsafeMutablePointer<sockaddr>) -> String {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(ptr, socklen_t(ptr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                return String(cString: host)
            }
            let address = ip(addr)
            if Self.isPrivate(address) && !address.hasPrefix("169.254.") { networks.append(.init(address: address, mask: ip(netmask), interface: name)) }
        }
        guard let value = networks.sorted(by: { $0.interface < $1.interface }).first else { throw MirrorError("Conecte o Mac e a TV à mesma rede local (Wi-Fi ou Ethernet).") }
        return value
    }
    public static func isPrivate(_ host: String) -> Bool {
        let p = host.split(separator: ".").compactMap { UInt8($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1]))
    }
    public func contains(_ host: String) -> Bool {
        func value(_ s: String) -> UInt32? {
            let p = s.split(separator: ".").compactMap { UInt8($0) }; guard p.count == 4 else { return nil }
            return p.reduce(0) { ($0 << 8) | UInt32($1) }
        }
        guard let a = value(address), let b = value(host), let m = value(mask) else { return false }
        return (a & m) == (b & m)
    }
}
public func xmlEscape(_ string: String) -> String {
    string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
}
