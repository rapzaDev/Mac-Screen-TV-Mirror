import SwiftUI

struct LatencyView: View {
    @ObservedObject var session: MirrorSession
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss.S"; return formatter
    }()
    var body: some View {
        VStack(spacing: 18) {
            Text("Atraso aproximado da imagem").font(.title2.bold())
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                Text(Self.formatter.string(from: context.date)).font(.system(size: 66, weight: .semibold, design: .monospaced))
            }
            Text("Compare este horário no Mac com o horário espelhado na TV.\nA diferença é o atraso visual aproximado; não é uma medição automática.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if session.state.active {
                Button(role: .destructive) { Task { await session.stop() } } label: { Label("Parar espelhamento", systemImage: "stop.fill") }
            }
        }.padding(28).frame(width: 580)
    }
}
