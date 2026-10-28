import XCTest
import CoreGraphics
import CoreVideo
import Darwin
@testable import MirrorCore

final class CoreTests: XCTestCase {
    func testPrivateNetworksAndSubnet() throws {
        let network = LocalNetwork(address: "192.168.2.10", mask: "255.255.255.0", interface: "en0")
        XCTAssertTrue(network.contains("192.168.2.255")); XCTAssertFalse(network.contains("192.168.3.2"))
        XCTAssertFalse(network.contains("192.168.2.999")); XCTAssertFalse(LocalNetwork.isPrivate("8.8.8.8"))
        XCTAssertTrue(LocalNetwork.isPrivate("172.31.1.1")); XCTAssertFalse(LocalNetwork.isPrivate("172.32.1.1"))
    }
    func testByteRanges() {
        XCTAssertEqual(LocalHTTPServer.parseRange("Range: bytes=0-187", length: 376), 0..<188)
        XCTAssertEqual(LocalHTTPServer.parseRange("Range: bytes=188-", length: 376), 188..<376)
        XCTAssertEqual(LocalHTTPServer.parseRange("Range: bytes=-188", length: 376), 188..<376)
        XCTAssertNil(LocalHTTPServer.parseRange("Range: bytes=999-", length: 376))
        XCTAssertNil(LocalHTTPServer.parseRange("Range: bytes=0-1,3-4", length: 376))
    }
    func testQualityAndStates() {
        XCTAssertEqual(Quality.balanced.width, 1280); XCTAssertEqual(Quality.balanced.height, 720)
        XCTAssertEqual(Quality.economy.fps, 24); XCTAssertEqual(Quality.quality.bitrate, 5_000_000)
        XCTAssertTrue(SessionState.preparing.active); XCTAssertTrue(SessionState.streaming.active)
        XCTAssertFalse(SessionState.error.active); XCTAssertFalse(SessionState.disconnected.active)
    }
    func testUPnPDescriptionDoesNotImplyPlaybackCompatibility() throws {
        let xml = Data("<root><device><friendlyName>Samsung test</friendlyName><modelName>T4300</modelName><serviceList><service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/control</controlURL></service></serviceList></device></root>".utf8)
        let network = LocalNetwork(address: "192.168.2.10", mask: "255.255.255.0", interface: "en0")
        let device = try DeviceDiscovery.parseDescription(xml, url: URL(string: "http://192.168.2.2:9197/dmr")!, network: network)
        XCTAssertTrue(device.hasTransport); XCTAssertFalse(device.advertisesH264TS)
        XCTAssertEqual(device.transport?.absoluteString, "http://192.168.2.2:9197/control")
        let malicious = Data(String(decoding: xml, as: UTF8.self).replacingOccurrences(of: ">/control<", with: ">http://8.8.8.8/control<").utf8)
        XCTAssertNil(try DeviceDiscovery.parseDescription(malicious, url: device.descriptionURL, network: network).transport)
    }
    func testEncoderRejectsUseAfterStop() throws {
        let encoder = try H264Encoder(quality: .economy), source = try SyntheticSource(quality: .economy)
        let frame = try XCTUnwrap(source.latest()); encoder.stop()
        XCTAssertThrowsError(try encoder.encode(frame, index: 0))
    }
    func testCompatibilityLetterboxAndBoundedBuffers() throws {
        var input: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 100, 100, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &input), kCVReturnSuccess)
        let square = try XCTUnwrap(input)
        CVPixelBufferLockBaseAddress(square, [])
        memset(CVPixelBufferGetBaseAddress(square), 255, CVPixelBufferGetBytesPerRow(square) * 100)
        CVPixelBufferUnlockBaseAddress(square, [])
        let renderer = try LetterboxRenderer(quality: .balanced)
        var held: [CVPixelBuffer] = []
        for _ in 0..<5 { held.append(try XCTUnwrap(renderer.render(square))) }
        XCTAssertNil(renderer.render(square)) // Encoder/client backpressure must not grow the pool.
        let frame = try XCTUnwrap(held.first)
        XCTAssertEqual(CVPixelBufferGetWidth(frame), 1280); XCTAssertEqual(CVPixelBufferGetHeight(frame), 720)
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        let bytes = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(frame)
        XCTAssertLessThan(bytes[360 * stride + 10 * 4], 3) // Black left pillar.
        XCTAssertGreaterThan(bytes[360 * stride + 640 * 4], 250) // White square centered without stretching.
        CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        held.removeAll()
    }
    func testCompatibilitySourceStopReleasesResources() async {
        let source = CompatibilityScreenSource()
        XCTAssertNil(source.latest()); await source.stop(); await source.stop(); XCTAssertNil(source.latest())
    }
    func testSyntheticSourceReleasesPool() async throws {
        let source = try SyntheticSource(quality: .economy)
        XCTAssertNotNil(source.latest()); await source.stop(); XCTAssertNil(source.latest()); await source.stop()
    }
    func testUnexpectedMuxerExitReportsFailureAndCleansUp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacMirror-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let muxer = try HLSMuxer(quality: .economy, directory: directory)
        let failed = expectation(description: "Falha do subprocesso reportada")
        muxer.onFailure = { _ in failed.fulfill() }
        let pid = muxer.processIdentifier
        XCTAssertEqual(kill(pid, SIGKILL), 0)
        await fulfillment(of: [failed], timeout: 5)
        muxer.stop(); muxer.stop()
        XCTAssertNotEqual(kill(pid, 0), 0)
    }
    @MainActor func testStopWhilePreparingDoesNotResurrectSession() async throws {
        let session = MirrorSession()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("receiver/web")
        let task = Task { await session.start(displayID: CGMainDisplayID(), quality: .economy, device: nil, webRoot: root, synthetic: true, port: 18877) }
        while session.state == .idle { try await Task.sleep(nanoseconds: 1_000_000) }
        await session.stop(); await task.value
        XCTAssertEqual(session.state, .disconnected); XCTAssertNil(session.server); XCTAssertNil(session.directory)
    }
    @MainActor func testSessionFailureReleasesPortAndTemporaryFiles() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("receiver/web")
        let session = MirrorSession()
        await session.start(displayID: CGMainDisplayID(), quality: .quality, device: nil, webRoot: root, synthetic: true, port: 18877)
        XCTAssertEqual(session.state, .error); XCTAssertNil(session.server); XCTAssertNil(session.directory)
        await session.stop(); XCTAssertEqual(session.state, .disconnected)
    }
    @MainActor func testLiveSessionLifecycleAndHTTP() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("receiver/web")
        let session = MirrorSession()
        for _ in 0..<2 {
            await session.start(displayID: CGMainDisplayID(), quality: .economy, device: nil, webRoot: root, synthetic: true, port: 18877)
            XCTAssertEqual(session.state, .streaming, session.message)
            guard let server = session.server, let directory = session.directory else { XCTFail(session.message); return }
            let previous = server.receiverURL
            // Duplicate Start must not create a second session or replace its access token.
            await session.start(displayID: CGMainDisplayID(), quality: .economy, device: nil, webRoot: root, synthetic: true, port: 18877)
            XCTAssertEqual(session.receiverURL, previous)
            let (playlist, response) = try await URLSession.shared.data(from: URL(string: server.streamURL)!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let text = String(decoding: playlist, as: UTF8.self)
            XCTAssertTrue(text.hasPrefix("#EXTM3U")); XCTAssertTrue(text.contains("#EXT-X-TARGETDURATION:")); XCTAssertFalse(text.contains("#EXT-X-ENDLIST"))
            let segments = text.split(separator: "\n").filter { $0.hasSuffix(".ts") }
            XCTAssertFalse(segments.isEmpty); XCTAssertLessThanOrEqual(segments.count, 6)
            let segmentURL = URL(string: server.streamURL)!.deletingLastPathComponent().appendingPathComponent(String(try XCTUnwrap(segments.first)))
            let (bytes, segmentResponse) = try await URLSession.shared.data(from: segmentURL)
            XCTAssertEqual((segmentResponse as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertGreaterThan(bytes.count, 188); XCTAssertEqual(bytes.count % 188, 0)
            for offset in stride(from: 0, to: bytes.count, by: 188) { XCTAssertEqual(bytes[offset], 0x47) }
            var request = URLRequest(url: segmentURL); request.setValue("bytes=0-187", forHTTPHeaderField: "Range")
            let (part, partialResponse) = try await URLSession.shared.data(for: request)
            XCTAssertEqual(part.count, 188); XCTAssertEqual((partialResponse as? HTTPURLResponse)?.statusCode, 206)
            let (_, denied) = try await URLSession.shared.data(from: URL(string: "\(server.baseURL)/s/bad/live.m3u8")!)
            XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 403)
            // New HTTP clients can join the same ongoing session.
            let (_, rejoined) = try await URLSession.shared.data(from: URL(string: server.streamURL)!)
            XCTAssertEqual((rejoined as? HTTPURLResponse)?.statusCode, 200)
            await session.stop()
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path)); XCTAssertNil(session.server)
            XCTAssertEqual(session.state, .disconnected)
            do { _ = try await URLSession.shared.data(from: URL(string: server.streamURL)!); XCTFail("Endpoint permaneceu aberto após Stop") } catch { }
        }
    }
}
