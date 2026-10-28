import SwiftUI
import AppKit

struct MainView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel
    @ObservedObject var session: MirrorSession
    private var capturing: Bool { session.state == .streaming || session.state == .reconnecting }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 34, weight: .medium)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MacMirror").font(.largeTitle.bold())
                        Text("Sua tela, na sua rede.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if capturing { Label("CAPTURA ATIVA", systemImage: "record.circle.fill").font(.caption.bold()).foregroundStyle(.red).accessibilityLabel("Captura da tela ativa") }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Dispositivo de destino").font(.headline); Spacer()
                            Button { Task { await model.discover() } } label: { Label("Buscar", systemImage: "arrow.clockwise") }.disabled(model.busy || session.state.active)
                        }
                        Picker("Destino", selection: $model.selectedIP) {
                            Text("Receptor web · abrir na TV").tag("")
                            ForEach(model.devices) { device in Text("\(device.name) · \(device.ip)").tag(device.ip) }
                        }.labelsHidden().frame(maxWidth: .infinity)
                        if let device = model.devices.first(where: { $0.ip == model.selectedIP }) {
                            Text("\(device.model) · \(device.capabilityLabel)").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack { TextField("IP da TV, ex.: 192.168.0.13", text: $model.manualIP); Button("Testar IP") { Task { await model.manual() } }.disabled(model.busy) }
                        Toggle("Iniciar reprodução na TV por DLNA", isOn: $model.useDLNA)
                        if model.useDLNA { Toggle("Tentar HLS pelo DLNA (alternativa ao MPEG-TS)", isOn: $model.useHLSDLNA).font(.caption) }
                    }.padding(8)
                }.disabled(session.state.active)
                HStack(alignment: .top, spacing: 16) {
                    GroupBox("Monitor de origem") {
                        Picker("Monitor", selection: $model.displayID) { ForEach(model.displays) { display in Text(display.label).tag(display.id) } }.labelsHidden().padding(8)
                    }
                    GroupBox("Qualidade da transmissão") {
                        VStack(alignment: .leading) {
                            Picker("Qualidade", selection: $model.quality) { ForEach(Quality.allCases) { Text($0.label).tag($0) } }.labelsHidden()
                            if model.quality == .quality { Toggle("Confirmei 1080p neste receptor", isOn: $model.confirmed1080).font(.caption) }
                        }.padding(8)
                    }
                }.disabled(session.state.active)
                GroupBox("Som e atraso") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Transmitir áudio do sistema para a TV", isOn: $model.audioEnabled).disabled(session.state.active)
                        Text("Durante a transmissão, o som dos aplicativos sai somente na TV. Ao parar, volta ao Mac.").font(.caption).foregroundStyle(.secondary)
                        Picker("Buffer", selection: $model.tuning) { ForEach(StreamTuning.allCases) { Text($0.label).tag($0) } }.disabled(session.state.active)
                        Button("Comparar atraso com um relógio") { openWindow(id: "latency") }
                        Text("Menor atraso reduz a espera no Mac. O buffer interno da TV também influencia o resultado.").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Circle().fill(session.state == .error ? .red : capturing ? .green : .secondary).frame(width: 9, height: 9)
                        Text(session.state.rawValue).font(.headline)
                        if session.state == .preparing { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    Text(session.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if capturing {
                        HStack(spacing: 24) {
                            metric("Vídeo", "\(model.quality.width)×\(model.quality.height)")
                            metric("FPS medido", String(format: "%.1f", session.metrics.fps))
                            metric("H.264 medido", String(format: "%.2f Mbps", session.metrics.mbps))
                            metric("IPs ativos", "\(session.metrics.clients)")
                        }
                        Text("\(session.metrics.captureBackend) · Encoder \(session.metrics.hardware ? "por hardware" : "por software") · Frames: \(session.metrics.frames) · Descartados: \(session.metrics.dropped)").font(.caption).foregroundStyle(.secondary)
                    }
                    if capturing && session.metrics.audioEnabled {
                        Label(session.metrics.audioDBFS > -65 ? String(format: "Áudio capturado · %.0f dBFS", session.metrics.audioDBFS) : "Áudio ativo · aguardando som dos aplicativos", systemImage: "speaker.wave.2.fill").font(.caption).foregroundStyle(.secondary)
                    }
                    if !session.transportStatus.isEmpty { Text(session.transportStatus).font(.callout).foregroundStyle(.secondary) }
                }
                HStack {
                    Button { Task { await model.start() } } label: { Label("Iniciar espelhamento", systemImage: "play.fill").frame(minWidth: 190) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy || session.state.active || (model.quality == .quality && !model.confirmed1080)).keyboardShortcut(.return, modifiers: [.command])
                    Button(role: .destructive) { Task { await session.stop() } } label: { Label("Parar espelhamento", systemImage: "stop.fill") }.controlSize(.large).disabled(!session.state.active)
                }
                if !session.receiverURL.isEmpty {
                    GroupBox("Abrir o receptor na Samsung") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Se o DLNA não abrir a imagem, acesse no navegador da TV:")
                            Text(session.receiverURL.components(separatedBy: "#")[0]).font(.system(.title3, design: .monospaced).bold()).textSelection(.enabled)
                            Text("Código: \(session.sessionCode)").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            HStack {
                                Button("Copiar endereço completo") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.receiverURL, forType: .string) }
                                Button("Testar neste Mac") { NSWorkspace.shared.open(URL(string: session.receiverURL + "&muted=1")!) }
                            }
                            Text("Aguarde o vídeo avançar. Se o navegador informar HLS indisponível, use o receptor Tizen descrito no README. Não compartilhe o código da sessão.").font(.caption).foregroundStyle(.secondary)
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text(model.notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Áudio do sistema opcional · Microfone não capturado · Sem limite de duração").font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minWidth: 680, minHeight: 690)
    }
    private func metric(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(name).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(.body, design: .monospaced)) }
    }
}
