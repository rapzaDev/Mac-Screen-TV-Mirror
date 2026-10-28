import Foundation
import Darwin

public struct TVDevice: Identifiable, Equatable {
    public var id: String { ip }
    public let ip: String
    public let name: String
    public let model: String
    public let descriptionURL: URL
    public let transport: URL?
    public let connectionManager: URL?
    public var protocols: String = ""
    public var hasTransport: Bool { transport != nil }
    public var advertisesH264TS: Bool { protocols.contains("AVC_TS") || protocols.contains("video/mpeg:*") }
    public var capabilityLabel: String { advertisesH264TS ? "DLNA anuncia H.264/TS · reprodução a verificar" : hasTransport ? "DLNA detectado · formatos a verificar" : "Detectado · reprodução não confirmada" }
}
public enum DeviceDiscovery {
    public static func discover(network: LocalNetwork) async throws -> [TVDevice] {
        let locations = await Task.detached { ssdp(network: network) }.value
        var devices: [String: TVDevice] = [:]
        for url in locations {
            if let device = try? await inspect(url: url, network: network), device.name.lowercased().contains("samsung") || device.hasTransport {
                if devices[device.ip]?.hasTransport != true || device.hasTransport { devices[device.ip] = device }
            }
        }
        return devices.values.sorted { $0.name < $1.name }
    }
    private static func ssdp(network: LocalNetwork) -> [URL] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }; defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var local = in_addr(); inet_pton(AF_INET, network.address, &local)
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &local, socklen_t(MemoryLayout<in_addr>.size))
        var dest = sockaddr_in(); dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); dest.sin_family = sa_family_t(AF_INET); dest.sin_port = UInt16(1900).bigEndian; inet_pton(AF_INET, "239.255.255.250", &dest.sin_addr)
        let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: ssdp:all\r\n\r\n"
        message.withCString { ptr in withUnsafePointer(to: &dest) { address in address.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = sendto(fd, ptr, strlen(ptr), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
        let deadline = Date().addingTimeInterval(4)
        var result = Set<URL>(), buffer = [UInt8](repeating: 0, count: 65536)
        while Date() < deadline {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { continue }
            let message = String(decoding: buffer.prefix(count), as: UTF8.self)
            for line in message.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("location:") {
                if let url = URL(string: String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)), url.scheme == "http", let host = url.host, network.contains(host) { result.insert(url) }
            }
        }
        return Array(result.prefix(24))
    }
    public static func manual(ip: String, network: LocalNetwork) async throws -> TVDevice {
        guard network.contains(ip), LocalNetwork.isPrivate(ip) else { throw MirrorError("Informe um IPv4 na mesma rede do Mac (\(network.address)).") }
        // Samsung's description endpoint is tried first. SSDP supplies other vendors' ports.
        for path in [":9197/dmr", ":49152/description.xml", ":8001/api/v2/"] {
            guard let url = URL(string: "http://\(ip)\(path)") else { continue }
            if path.contains("api/v2"), let (data, _) = try? await fetch(url),
               let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let device = info["device"] as? [String: Any]
                return TVDevice(ip: ip, name: info["name"] as? String ?? ip, model: device?["modelName"] as? String ?? "Modelo não informado", descriptionURL: url, transport: nil, connectionManager: nil)
            }
            if let device = try? await inspect(url: url, network: network) { return device }
        }
        throw MirrorError("A TV não respondeu aos serviços conhecidos. Verifique o IP e mantenha a TV ligada. O receptor web continua disponível sem DLNA.")
    }
    public static func parseDescription(_ data: Data, url: URL, network: LocalNetwork) throws -> TVDevice {
        let doc = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        func first(_ node: XMLNode, _ query: String) -> String { (try? node.nodes(forXPath: query).first?.stringValue) ?? "" }
        let name = first(doc, "//*[local-name()='friendlyName']"), model = first(doc, "//*[local-name()='modelName']")
        guard !name.isEmpty, let ip = url.host, network.contains(ip) else { throw MirrorError("Descrição UPnP inválida.") }
        func service(_ name: String) -> URL? {
            guard let node = try? doc.nodes(forXPath: "//*[local-name()='service'][contains(*[local-name()='serviceType'], '\(name)')]").first else { return nil }
            let path = first(node, "*[local-name()='controlURL']")
            guard !path.isEmpty, let resolved = URL(string: path, relativeTo: url)?.absoluteURL, resolved.host == ip, resolved.scheme == "http" else { return nil }
            return resolved
        }
        return TVDevice(ip: ip, name: name, model: model, descriptionURL: url, transport: service("AVTransport:"), connectionManager: service("ConnectionManager:"))
    }
    public static func inspect(url: URL, network: LocalNetwork) async throws -> TVDevice {
        let (data, _) = try await fetch(url)
        var device = try parseDescription(data, url: url, network: network)
        if let manager = device.connectionManager, let reply = try? await DLNA.soap(url: manager, service: "ConnectionManager", action: "GetProtocolInfo", arguments: [:]) {
            device.protocols = (try? XMLDocument(data: reply, options: [.nodeLoadExternalEntitiesNever]).nodes(forXPath: "//*[local-name()='Sink']").first?.stringValue) ?? ""
        }
        return device
    }
    public static func fetch(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.httpMethod = "GET"
        let result = try await URLSession.shared.data(for: request)
        guard let response = result.1 as? HTTPURLResponse, response.statusCode == 200, result.0.count < 1_048_576 else { throw MirrorError("Resposta de rede inválida.") }
        return result
    }
}
public enum DLNA {
    // Sender paced; moving beginning/end; streaming; DLNA 1.5. No byte/time seek is advertised for a live socket.
    public static let liveFeatures = "DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=8D100000000000000000000000000000"
    public static func soap(url: URL, service: String = "AVTransport", action: String, arguments: [String: String]) async throws -> Data {
        let type = "urn:schemas-upnp-org:service:\(service):1"
        let order = ["InstanceID", "CurrentURI", "CurrentURIMetaData", "Speed"]
        let args = arguments.sorted { (order.firstIndex(of: $0.key) ?? 99) < (order.firstIndex(of: $1.key) ?? 99) }.map { "<\($0.key)>\(xmlEscape($0.value))</\($0.key)>" }.joined()
        let body = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"\(type)\">\(args)</u:\(action)></s:Body></s:Envelope>"
        var request = URLRequest(url: url, timeoutInterval: 6); request.httpMethod = "POST"; request.httpBody = Data(body.utf8)
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type"); request.setValue("\"\(type)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let doc = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
            let description = (try? doc?.nodes(forXPath: "//*[local-name()='errorDescription']").first?.stringValue) ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            throw MirrorError("DLNA \(action): \(description)")
        }
        return data
    }
    public static func play(device: TVDevice, url: String, hls: Bool, stillActive: () async -> Bool = { true }) async throws {
        try Task.checkCancellation()
        guard await stillActive() else { throw CancellationError() }
        guard let control = device.transport else { throw MirrorError("A TV não anunciou AVTransport. Use o receptor web.") }
        let mime = hls ? "application/vnd.apple.mpegurl" : "video/mpeg"
        let features = hls ? "*" : liveFeatures
        let metadata = "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\"><item id=\"1\" parentID=\"0\" restricted=\"1\"><dc:title>MacMirror · Tela ao vivo</dc:title><upnp:class>object.item.videoItem</upnp:class><res protocolInfo=\"http-get:*:\(mime):\(features)\">\(xmlEscape(url))</res></item></DIDL-Lite>"
        _ = try await soap(url: control, action: "SetAVTransportURI", arguments: ["InstanceID":"0", "CurrentURI":url, "CurrentURIMetaData":metadata])
        try Task.checkCancellation()
        guard await stillActive() else { throw CancellationError() }
        _ = try await soap(url: control, action: "Play", arguments: ["InstanceID":"0", "Speed":"1"])
    }
    public static func stop(device: TVDevice) async { if let url = device.transport { _ = try? await soap(url: url, action: "Stop", arguments: ["InstanceID":"0"]) } }
    public static func transportState(device: TVDevice) async throws -> String {
        guard let url = device.transport else { throw MirrorError("Sem AVTransport.") }
        let data = try await soap(url: url, action: "GetTransportInfo", arguments: ["InstanceID":"0"])
        return (try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]).nodes(forXPath: "//*[local-name()='CurrentTransportState']").first?.stringValue) ?? "UNKNOWN"
    }
}
