import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit
import OSLog

@MainActor
final class AppModel: ObservableObject {
    let session = MirrorSession()
    @Published var devices: [TVDevice] = []
    @Published var selectedIP = ""
    @Published var manualIP = ""
    @Published var displays: [DisplayChoice] = []
    @Published var displayID = CGMainDisplayID()
    @Published var quality: Quality = .balanced
    @Published var audioEnabled = true
    @Published var tuning: StreamTuning = .responsive
    @Published var confirmed1080 = false
    @Published var useDLNA = true
    @Published var useHLSDLNA = false
    @Published var busy = false
    @Published var notice = "A descoberta não comprova reprodução. A imagem precisa ser confirmada na TV."
    private let logger = Logger(subsystem: "local.macmirror.app", category: "lifecycle")
    private var observers: [NSObjectProtocol] = []
    private var distributed: NSObjectProtocol?
    init() {
        refreshDisplays()
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in guard let self else { return }; if self.session.state.active { self.logger.info("stop=\(name.rawValue, privacy: .public)"); await self.session.stop(); self.notice = "Captura encerrada ao bloquear/suspender. Clique em Iniciar para retomar." } }
            })
        }
        distributed = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.logger.info("stop=screenIsLocked"); await self?.session.stop() }
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let before = self.displays.sorted { $0.id < $1.id }
                self.refreshDisplays()
                guard before != self.displays.sorted(by: { $0.id < $1.id }) else { self.logger.info("display notification without geometry change: ignored"); return }
                self.logger.info("stop=displayGeometryChanged")
                await self.session.stop(); self.notice = "Os monitores mudaram. Selecione a tela e inicie novamente."
            }
        })
    }
    func refreshDisplays() {
        // Enumerate display metadata without asking for capture permission at launch.
        var ids = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
        CGGetActiveDisplayList(32, &ids, &count)
        displays = ids.prefix(Int(count)).map { DisplayChoice(id: $0, width: CGDisplayPixelsWide($0), height: CGDisplayPixelsHigh($0)) }
        if !displays.contains(where: { $0.id == displayID }) { displayID = displays.first?.id ?? CGMainDisplayID() }
    }
    func discover() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            devices = try await DeviceDiscovery.discover(network: LocalNetwork.current())
            notice = devices.isEmpty ? "Nenhuma TV anunciou serviços. Informe o IP ou abra o receptor web após iniciar." : "\(devices.count) dispositivo(s) encontrado(s). Verifique os formatos e teste a reprodução."
            if selectedIP.isEmpty, !session.state.active, let samsung = devices.first(where: { $0.name.lowercased().contains("samsung") }) { selectedIP = samsung.ip }
        } catch { notice = error.localizedDescription }
    }
    func manual() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let device = try await DeviceDiscovery.manual(ip: manualIP.trimmingCharacters(in: .whitespaces), network: LocalNetwork.current())
            devices.removeAll { $0.ip == device.ip }; devices.append(device); selectedIP = device.ip
            notice = "Dispositivo respondeu. \(device.capabilityLabel)"
        } catch { notice = error.localizedDescription }
    }
    func start(synthetic: Bool = false) async {
        if !synthetic && !CGPreflightScreenCaptureAccess() {
            guard CGRequestScreenCaptureAccess() else {
                notice = "Autorize MacMirror em Ajustes do Sistema → Privacidade e Segurança → Gravação de Tela e Áudio do Sistema. Reabra o aplicativo se o macOS solicitar."; return
            }
        }
        await session.start(displayID: displayID, quality: quality, device: devices.first { $0.ip == selectedIP }, webRoot: Bundle.main.resourceURL!.appendingPathComponent("web"), synthetic: synthetic, autoPlay: useDLNA, hlsDLNA: useHLSDLNA, qualityConfirmed: confirmed1080, audioEnabled: audioEnabled, tuning: tuning)
    }
    func integration() async {
        let args = CommandLine.arguments
        func option(_ name: String) -> String? { guard let i = args.firstIndex(of: name), args.count > i + 1 else { return nil }; return args[i + 1] }
        guard args.contains("--integration") else { return }
        if let ip = option("--tv") { manualIP = ip; await manual() }
        useHLSDLNA = args.contains("--hls-dlna")
        audioEnabled = !args.contains("--no-audio")
        if args.contains("--stable") { tuning = .stable }
        await start(synthetic: args.contains("--synthetic"))
        print("INTEGRATION state=\(session.state.rawValue) message=\(session.message)"); fflush(stdout)
        if session.state == .streaming {
            print("RECEIVER \(session.receiverURL)"); print("HLS \(session.streamURL)"); fflush(stdout)
            let seconds = Int(option("--seconds") ?? "120") ?? 120
            for tick in 0..<seconds {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if tick % 5 == 0 {
                    await session.refreshTransport()
                    let m = session.metrics
                    print(String(format: "t=%d frames=%d fps=%.2f Mbps=%.3f hw=%@ clients=%d drops=%d %@", tick, m.frames, m.fps, m.mbps, m.hardware.description, m.clients, m.dropped, session.transportStatus)); fflush(stdout)
                }
            }
            if let server = session.server { print("HTTP_STATS \(server.snapshot())") }
            await session.stop(); print("INTEGRATION_STOPPED"); fflush(stdout)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { await model.session.stop(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MacMirrorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("MacMirror") {
            MainView(model: model, session: model.session)
                .onAppear { delegate.model = model; NSApp.activate(ignoringOtherApps: true) }
                .task { if CommandLine.arguments.contains("--integration") { await model.integration() } else { await model.discover() } }
        }.defaultSize(width: 720, height: 790).windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }
        Window("Comparar atraso", id: "latency") {
            LatencyView(session: model.session)
        }.defaultSize(width: 580, height: 290).windowResizability(.contentSize)
    }
}
