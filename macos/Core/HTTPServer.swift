import Foundation
import Network
import Security

/// Single-request HTTP/1.1 server, bound to one LAN address. All connection state belongs to `queue`.
public final class LocalHTTPServer {
    private let queue = DispatchQueue(label: "MacMirror.http")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var live: [UUID: Int] = [:]
    private var clients: [String: Date] = [:]
    private var ring = Data()
    private var ringStarted = Date()
    private var peers: [UUID: String] = [:]
    private var receivedBytes = 0
    private var requestLog: [String: Int] = [:]
    private let network: LocalNetwork
    public let port: UInt16
    public let token: String
    private let directory: URL
    private let webRoot: URL
    private let startupCacheSeconds: Double
    private var statusProvider: (() -> Data)?
    public var baseURL: String { "http://\(network.address):\(port)" }
    public var streamURL: String { "\(baseURL)/s/\(token)/live.m3u8" }
    public var transportURL: String { "\(baseURL)/s/\(token)/live.ts" }
    public var receiverURL: String { "\(baseURL)/tv#\(token)" }
    public init(network: LocalNetwork, port: UInt16 = 8787, directory: URL, webRoot: URL, token: String? = nil, tuning: StreamTuning = .stable) {
        self.network = network; self.port = port; self.directory = directory; self.webRoot = webRoot; self.startupCacheSeconds = tuning.startupCacheSeconds
        var random = [UInt8](repeating: 0, count: 8)
        precondition(SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess)
        self.token = token ?? random.map { String(format: "%02x", $0) }.joined()
    }
    public func start(status: @escaping () -> Data) async throws {
        statusProvider = status
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(network.address), port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        self.listener = listener
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = StartOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { continuation.resume() }
                case .failed(let error): if once.claim() { continuation.resume(throwing: error) }
                case .cancelled: if once.claim() { continuation.resume(throwing: MirrorError("Servidor cancelado.")) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 32, case .hostPort(let host, _) = connection.endpoint, network.contains("\(host)") else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection; peers[id] = "\(host)"
        connection.stateUpdateHandler = { [weak self] state in
            switch state { case .failed, .cancelled: self?.connections.removeValue(forKey: id); self?.live.removeValue(forKey: id); self?.peers.removeValue(forKey: id); default: break }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8) { [weak self, weak connection] in
            if self?.live[id] == nil { connection?.cancel() }
        }
        read(connection, id: id, buffer: Data(), peer: "\(host)")
    }
    private func read(_ connection: NWConnection, id: UUID, buffer: Data, peer: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var bytes = buffer; if let data { bytes.append(data) }
            guard bytes.count <= 16384 else { self.respond(connection, status: 431); return }
            if let end = bytes.range(of: Data("\r\n\r\n".utf8)), let headers = String(data: bytes[..<end.lowerBound], encoding: .utf8) {
                self.handle(connection, id: id, headers: headers, peer: peer)
            } else if done || error != nil { connection.cancel() }
            else { self.read(connection, id: id, buffer: bytes, peer: peer) }
        }
    }
    private func handle(_ connection: NWConnection, id: UUID, headers: String, peer: String) {
        let lines = headers.components(separatedBy: "\r\n"), first = lines.first?.split(separator: " ") ?? []
        guard first.count == 3, first[0] == "GET" || first[0] == "HEAD" else { respond(connection, status: 405); return }
        let head = first[0] == "HEAD", path = String(first[1]).components(separatedBy: "?")[0]
        if path == "/tv" || path == "/" {
            guard let data = try? Data(contentsOf: webRoot.appendingPathComponent("index.html")) else { respond(connection, status: 404); return }
            respond(connection, data: data, mime: "text/html; charset=utf-8", head: head); return
        }
        if path == "/receiver.js" {
            guard let data = try? Data(contentsOf: webRoot.appendingPathComponent("receiver.js")) else { respond(connection, status: 404); return }
            respond(connection, data: data, mime: "application/javascript", head: head); return
        }
        let prefix = "/s/\(token)/"
        guard path.hasPrefix(prefix) else { respond(connection, status: 403); return }
        let file = String(path.dropFirst(prefix.count))
        let allowed = file == "live.m3u8" || file == "live.ts" || file == "status" || (file.hasPrefix("seg") && file.hasSuffix(".ts") && file.dropFirst(3).dropLast(3).allSatisfy(\.isNumber))
        guard allowed else { respond(connection, status: 404); return }
        if file != "status" {
            clients[peer] = Date(); requestLog[file == "live.ts" ? "ts" : file == "live.m3u8" ? "playlist" : "segment", default: 0] += 1
            // Keep bounded diagnostics, without session tokens or full viewer URLs.
            if requestLog.values.reduce(0, +) <= 12 { print("HTTP \(peer) \(file)") }
        }
        if file == "status" { respond(connection, data: statusProvider?() ?? Data("{}".utf8), mime: "application/json", head: head); return }
        if file == "live.ts" {
            let headers = "HTTP/1.0 200 OK\r\nContent-Type: video/mpeg\r\nCache-Control: no-store\r\nConnection: close\r\ncontentFeatures.dlna.org: \(DLNA.liveFeatures)\r\ntransferMode.dlna.org: Streaming\r\n\r\n"
            if head { connection.send(content: Data(headers.utf8), completion: .contentProcessed { _ in connection.cancel() }); return }
            live[id] = 0
            connection.send(content: Data(headers.utf8), completion: .contentProcessed { _ in })
            if !ring.isEmpty {
                let alignment = (188 - (receivedBytes - ring.count) % 188) % 188
                if ring.count > alignment { sendStreamBytes(Data(ring.dropFirst(alignment)), connection: connection, id: id) }
            }
            return
        }
        let url = directory.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { respond(connection, status: 503, extra: "Retry-After: 1\r\n"); return }
        let mime = file.hasSuffix("m3u8") ? "application/vnd.apple.mpegurl" : "video/mp2t"
        var extra = ""
        if let line = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
            guard let range = Self.parseRange(line, length: data.count) else { respond(connection, status: 416, extra: "Content-Range: bytes */\(data.count)\r\n"); return }
            extra = "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)\r\n"
            respond(connection, status: 206, data: data.subdata(in: range), mime: mime, head: head, extra: extra); return
        }
        respond(connection, data: data, mime: mime, head: head)
    }
    public static func parseRange(_ value: String, length: Int) -> Range<Int>? {
        guard length > 0, let part = value.components(separatedBy: "bytes=").last, !part.contains(",") else { return nil }
        let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
        guard pair.count == 2 else { return nil }
        if pair[0].isEmpty { guard let n = Int(pair[1]), n > 0 else { return nil }; return max(0, length - n)..<length }
        guard let start = Int(pair[0]), start >= 0, start < length else { return nil }
        let end = pair[1].isEmpty ? length - 1 : Int(pair[1]) ?? -1
        guard end >= start else { return nil }; return start..<(min(end, length - 1) + 1)
    }
    private func respond(_ connection: NWConnection, status: Int = 200, data: Data = Data(), mime: String = "text/plain", head: Bool = false, extra: String = "") {
        let reason = [200:"OK", 206:"Partial Content", 403:"Forbidden", 404:"Not Found", 405:"Method Not Allowed", 416:"Range Not Satisfiable", 431:"Request Header Fields Too Large", 503:"Service Unavailable"][status] ?? "Error"
        var packet = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\nAccept-Ranges: bytes\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n\(extra)\r\n".utf8)
        if !head { packet.append(data) }
        connection.send(content: packet, completion: .contentProcessed { _ in connection.cancel() })
    }
    private func sendStreamBytes(_ bytes: Data, connection: NWConnection, id: UUID) {
        guard let pending = live[id] else { return }
        if pending + bytes.count > 1_048_576 { live.removeValue(forKey: id); connection.cancel(); return }
        live[id] = pending + bytes.count
        let chunk = bytes // HTTP/1.0 close-delimited live response; no invented Content-Length.
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { self.live.removeValue(forKey: id); connection.cancel() }
            else if let count = self.live[id] { self.live[id] = max(0, count - bytes.count) }
        })
    }
    public func broadcast(_ bytes: Data) {
        // Synchronous handoff bounds producer -> network queue memory as well as per-client buffers.
        queue.sync {
            if Date().timeIntervalSince(ringStarted) > startupCacheSeconds { ring.removeAll(keepingCapacity: true); ringStarted = Date() }
            ring.append(bytes); receivedBytes += bytes.count
            for id in live.keys { if let ip = peers[id] { clients[ip] = Date() } }
            // MPEG-TS packet boundaries (188 bytes) are preserved in the rolling startup cache.
            if ring.count > 524_288 { let drop = ((ring.count - 524_288 + 187) / 188) * 188; ring.removeFirst(min(drop, ring.count)) }
            for id in Array(live.keys) { if let c = connections[id] { sendStreamBytes(bytes, connection: c, id: id) } }
        }
    }
    public func snapshot() -> (clients: Int, live: Int, bytes: Int, requests: [String: Int]) {
        queue.sync { clients = clients.filter { Date().timeIntervalSince($0.value) < 12 }; return (clients.count, live.count, receivedBytes, requestLog) }
    }
    public func stop() {
        queue.sync {
            listener?.cancel(); listener = nil
            for c in connections.values { c.cancel() }
            connections.removeAll(); live.removeAll(); peers.removeAll(); clients.removeAll(); ring.removeAll()
        }
    }
}

private final class StartOnce: @unchecked Sendable {
    private let lock = NSLock(); private var claimed = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if claimed { return false }; claimed = true; return true }
}
