import SwiftUI
import ServiceManagement

// ---------------------------------------------------------------- модель для UI

final class UIModel: ObservableObject {
    static let shared = UIModel()
    @Published var s = EngineSnapshot()
    @Published var loginItem = false

    func apply(_ snap: EngineSnapshot) {
        s = snap
        if #available(macOS 13.0, *) {
            loginItem = SMAppService.mainApp.status == .enabled
        }
    }
}

// ---------------------------------------------------------------- палитра

enum Neon {
    static let bg1 = Color(red: 0.02, green: 0.04, blue: 0.10)
    static let bg2 = Color(red: 0.08, green: 0.02, blue: 0.16)
    static let cyan = Color(red: 0.0, green: 0.9, blue: 1.0)
    static let violet = Color(red: 0.62, green: 0.4, blue: 1.0)
    static let green = Color(red: 0.2, green: 1.0, blue: 0.6)
    static let amber = Color(red: 1.0, green: 0.75, blue: 0.2)
    static let red = Color(red: 1.0, green: 0.3, blue: 0.4)
    static let dim = Color.white.opacity(0.45)
    static let card = Color.white.opacity(0.055)
}

func pingColor(_ ms: Int) -> Color {
    ms < 600 ? Neon.green : (ms < 1500 ? Neon.amber : Neon.red)
}

// ---------------------------------------------------------------- корневой экран

struct RootView: View {
    @ObservedObject var model = UIModel.shared
    @State private var newURL = ""
    @State private var showPresets = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Neon.bg1, Neon.bg2],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 12) {
                header
                statusBlock
                connectButton
                togglesRow
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        channelsCard
                        subsCard
                    }
                }
                footer
            }
            .padding(14)
        }
        .frame(width: 380, height: 660)
        .preferredColorScheme(.dark)
    }

    // -------------------------------------------------- шапка

    var header: some View {
        HStack {
            Text("AUTO//VPN")
                .font(.system(size: 17, weight: .black, design: .monospaced))
                .tracking(3)
                .foregroundStyle(LinearGradient(colors: [Neon.cyan, Neon.violet],
                                                startPoint: .leading, endPoint: .trailing))
            Spacer()
            Text("fastest channel wins")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Neon.dim)
        }
    }

    // -------------------------------------------------- статус

    var statusOn: Bool { model.s.running && model.s.failCount < 2 }

    var statusBlock: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [statusColor.opacity(0.9), statusColor.opacity(0.05)],
                                         center: .center, startRadius: 2, endRadius: 30))
                    .frame(width: 56, height: 56)
                Circle()
                    .stroke(statusColor, lineWidth: 1.5)
                    .frame(width: 56, height: 56)
                    .shadow(color: statusColor.opacity(0.9), radius: statusOn ? 10 : 2)
                Image(systemName: statusOn ? "bolt.fill" : "bolt.slash")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(statusColor)
                if model.s.running && !model.s.now.isEmpty {
                    HStack(spacing: 6) {
                        Text(model.s.now)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(1)
                        if let ms = model.s.delays[model.s.now] {
                            Text("\(ms) мс")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(pingColor(ms))
                        }
                    }
                }
                if !model.s.externalIP.isEmpty && model.s.running {
                    Text("IP: \(model.s.externalIP)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Neon.dim)
                }
                if !model.s.busy.isEmpty {
                    Text("⟳ \(model.s.busy)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Neon.amber)
                        .lineLimit(1)
                } else if !model.s.lastError.isEmpty {
                    Text("⚠ \(model.s.lastError)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Neon.red)
                        .lineLimit(2)
                } else if !model.s.vpnConflict.isEmpty {
                    Text("⚠ отключи \(model.s.vpnConflict) — он перехватывает трафик")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Neon.amber)
                        .lineLimit(2)
                } else if model.s.running && !model.s.systemProxyOn {
                    Text("включи «СИСТ. ПРОКСИ» чтобы браузер шёл через VPN")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Neon.amber)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Neon.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(statusColor.opacity(0.35), lineWidth: 1))
    }

    var statusColor: Color {
        if !model.s.running { return Neon.dim }
        return model.s.failCount >= 2 ? Neon.amber : Neon.green
    }

    var statusTitle: String {
        if !model.s.running { return "ОТКЛЮЧЕНО" }
        return model.s.failCount >= 2 ? "ПЕРЕКЛЮЧАЮСЬ…" : "ПОДКЛЮЧЕНО"
    }

    // -------------------------------------------------- кнопка

    var connectButton: some View {
        Button {
            model.s.running ? Engine.shared.disconnect() : Engine.shared.connect()
        } label: {
            Text(model.s.running ? "ОТКЛЮЧИТЬ" : "ПОДКЛЮЧИТЬ")
                .font(.system(size: 13, weight: .black, design: .monospaced))
                .tracking(2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(LinearGradient(
                        colors: model.s.running
                            ? [Color.white.opacity(0.12), Color.white.opacity(0.06)]
                            : [Neon.cyan.opacity(0.85), Neon.violet.opacity(0.85)],
                        startPoint: .leading, endPoint: .trailing)))
                .overlay(Capsule().stroke(model.s.running ? Neon.dim : Neon.cyan, lineWidth: 1))
                .shadow(color: model.s.running ? .clear : Neon.cyan.opacity(0.5), radius: 8)
                .foregroundColor(.white)
        }
        .buttonStyle(.plain)
    }

    // -------------------------------------------------- переключатели

    var togglesRow: some View {
        HStack(spacing: 10) {
            neonToggle("СИСТ. ПРОКСИ", on: model.s.systemProxyOn) {
                let want = !model.s.systemProxyOn
                let conflict = model.s.vpnConflict
                DispatchQueue.global().async {
                    if !conflict.isEmpty && want {
                        Engine.shared.reportError("сначала отключи \(conflict)")
                        return
                    }
                    if SystemProxy.set(on: want) {
                        Engine.shared.setSystemProxyFlag(want)
                    } else {
                        Engine.shared.reportError("не удалось \(want ? "включить" : "выключить") системный прокси")
                    }
                }
            }
            neonToggle("АВТОЗАПУСК", on: model.loginItem) {
                guard #available(macOS 13.0, *) else { return }
                if SMAppService.mainApp.status == .enabled {
                    try? SMAppService.mainApp.unregister()
                } else {
                    try? SMAppService.mainApp.register()
                }
                Engine.shared.poke()
            }
        }
    }

    func neonToggle(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(on ? Neon.green : Color.white.opacity(0.2))
                    .frame(width: 7, height: 7)
                    .shadow(color: on ? Neon.green : .clear, radius: 4)
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(on ? .white : Neon.dim)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(Neon.card))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(on ? Neon.green.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // -------------------------------------------------- каналы

    var aliveSorted: [(String, Int)] {
        model.s.channelTags
            .compactMap { t in model.s.delays[t].map { (t, $0) } }
            .sorted { $0.1 < $1.1 }
    }

    var channelsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("КАНАЛЫ", right: "\(model.s.channelTags.count) / живых \(aliveSorted.count)")
            channelRow(tag: "auto", title: "АВТО — самый быстрый", ms: nil)
            ForEach(aliveSorted.prefix(20), id: \.0) { tag, ms in
                channelRow(tag: tag, title: tag, ms: ms)
            }
            if aliveSorted.isEmpty {
                Text(model.s.busy.isEmpty ? "нажми «Проверить» или «Обновить»" : "идёт проверка…")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Neon.dim)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Neon.card))
    }

    func channelRow(tag: String, title: String, ms: Int?) -> some View {
        let isSel = model.s.selected == tag
        return Button {
            Engine.shared.select(tag)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSel ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 9))
                    .foregroundColor(isSel ? Neon.cyan : Neon.dim)
                Text(title)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)
                Spacer()
                if let ms {
                    Capsule().fill(pingColor(ms))
                        .frame(width: max(6, 60 - CGFloat(ms) / 40), height: 3)
                        .opacity(0.8)
                    Text("\(ms)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(pingColor(ms))
                        .frame(width: 34, alignment: .trailing)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // -------------------------------------------------- списки

    var subsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("СПИСКИ", right: model.s.skipRU ? "RU-фильтр: вкл" : "")
            ForEach(model.s.subs) { sub in
                HStack(spacing: 8) {
                    Button {
                        Engine.shared.toggleSub(url: sub.url)
                    } label: {
                        Circle().fill(sub.enabled ? Neon.green : Color.white.opacity(0.15))
                            .frame(width: 8, height: 8)
                            .shadow(color: sub.enabled ? Neon.green : .clear, radius: 3)
                    }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sub.name)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(sub.enabled ? .white : Neon.dim)
                        Text(sub.url.replacingOccurrences(of: "https://", with: ""))
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundColor(Neon.dim)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        Engine.shared.removeSub(url: sub.url)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Neon.dim)
                    }.buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }
            HStack(spacing: 6) {
                TextField("https://… свой список vless", text: $newURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Neon.cyan.opacity(0.25), lineWidth: 1))
                Button {
                    let u = newURL.trimmingCharacters(in: .whitespaces)
                    guard u.hasPrefix("http") else { return }
                    let name = URL(string: u)?.host?
                        .replacingOccurrences(of: "raw.githubusercontent.com", with: "github") ?? "Свой список"
                    Engine.shared.addSub(name: name, url: u)
                    newURL = ""
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .black))
                        .foregroundColor(Neon.cyan)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Neon.card))
                        .overlay(Circle().stroke(Neon.cyan.opacity(0.5), lineWidth: 1))
                }.buttonStyle(.plain)
            }
            Button {
                withAnimation { showPresets.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showPresets ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text("ТОП-5 ПОПУЛЯРНЫХ")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .tracking(1)
                }
                .foregroundColor(Neon.violet)
            }.buttonStyle(.plain)
            if showPresets {
                ForEach(topPresets, id: \.url) { p in
                    let added = model.s.subs.contains { $0.url == p.url }
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.9))
                            Text(p.note)
                                .font(.system(size: 8.5, design: .monospaced))
                                .foregroundColor(Neon.dim)
                        }
                        Spacer()
                        Button {
                            Engine.shared.addSub(name: p.name, url: p.url)
                        } label: {
                            Image(systemName: added ? "checkmark" : "plus")
                                .font(.system(size: 10, weight: .black))
                                .foregroundColor(added ? Neon.green : Neon.violet)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Neon.card))
                                .overlay(Circle().stroke(
                                    (added ? Neon.green : Neon.violet).opacity(0.5), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(added)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Neon.card))
    }

    // -------------------------------------------------- низ

    func sectionTitle(_ t: String, right: String = "") -> some View {
        HStack {
            Text(t)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(2)
                .foregroundColor(Neon.cyan)
            Spacer()
            if !right.isEmpty {
                Text(right)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Neon.dim)
            }
        }
    }

    var footer: some View {
        HStack(spacing: 8) {
            footBtn("ПРОВЕРИТЬ") { Engine.shared.probe() }
            footBtn("ОБНОВИТЬ") { Engine.shared.refreshSubscription() }
            footBtn("ЛОГ") {
                NSWorkspace.shared.open(supportDir.appendingPathComponent("autovpn.log"))
            }
            footBtn("ВЫХОД") { NSApp.terminate(nil) }
        }
    }

    func footBtn(_ t: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundColor(.white.opacity(0.75))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Neon.card))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
