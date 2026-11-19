import Foundation

let PROXY_PORT = 2080
let API_PORT = 9092
let MAX_CHANNELS = 400

struct EngineSnapshot {
    var running = false
    var busy = ""
    var lastError = ""
    var externalIP = ""
    var selected = "auto"
    var now = ""
    var failCount = 0
    var delays: [String: Int] = [:]
    var channelTags: [String] = []
    var subs: [SubEntry] = []
    var systemProxyOn = false
    var skipRU = true
}

/// Принцип: подписка -> отсев -> sing-box -> самый быстрый -> самолечение.
final class Engine {
    static let shared = Engine()
    let q = DispatchQueue(label: "autovpn.engine")

    var settings = Settings.load()
    var channels: [Channel] = []
    var delays: [String: Int] = [:]      // tag -> мс (живые после последней проверки)
    var selected = "auto"                 // что выбрано в селекторе
    var running = false
    var busy = ""                        // "обновляю подписку" и т.п.
    var externalIP = ""
    var lastError = ""
    var failCount = 0
    var lastSubRefresh = Date.distantPast
    var now = ""                         // канал, который реально выбран сейчас
    var onChange: ((EngineSnapshot) -> Void)?  // дернуть UI (вызывается на main)

    private var proc: Process?
    private var expectStop = false

    private init() {
        if let d = try? Data(contentsOf: supportDir.appendingPathComponent("channels.json")),
           let c = try? JSONDecoder().decode([Channel].self, from: d) { channels = c }
    }

    /// только из q
    private func changed() {
        var s = EngineSnapshot()
        s.running = running; s.busy = busy; s.lastError = lastError
        s.externalIP = externalIP; s.selected = selected; s.now = now
        s.failCount = failCount; s.delays = delays
        s.channelTags = channels.map { $0.tag }
        s.subs = settings.subscriptions
        s.systemProxyOn = settings.systemProxyOn
        s.skipRU = settings.skipRU
        DispatchQueue.main.async { self.onChange?(s) }
    }

    func poke() { q.async { self.changed() } }

    private func saveChannels() {
        if let d = try? JSONEncoder().encode(channels) {
            try? d.write(to: supportDir.appendingPathComponent("channels.json"))
        }
    }

    // ------------------------------------------------------------ sing-box

    private var singboxPath: String? {
        var candidates: [String] = []
        // 1) рядом с AutoVPN внутри .app (бандл)
        if let exe = Bundle.main.executableURL {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("sing-box").path)
        }
        // 2) системный (brew) — для разработки из исходников
        candidates += [
            "/opt/homebrew/bin/sing-box",
            "/opt/homebrew/opt/sing-box/bin/sing-box",
            "/usr/local/bin/sing-box",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func outboundDict(_ c: Channel) -> [String: Any] {
        var o: [String: Any] = ["type": "vless", "tag": c.tag, "server": c.server,
                                "server_port": c.port, "uuid": c.uuid]
        if c.flow.hasPrefix("xtls-rprx-vision") { o["flow"] = "xtls-rprx-vision" }
        var tls: [String: Any] = ["enabled": true]
        if !c.sni.isEmpty { tls["server_name"] = c.sni }
        // reality без uTLS sing-box не принимает
        var fp = c.fp
        if fp.isEmpty && c.security == "reality" { fp = "chrome" }
        if !fp.isEmpty { tls["utls"] = ["enabled": true, "fingerprint": fp] }
        if c.security == "reality" {
            var r: [String: Any] = ["enabled": true, "public_key": c.pbk]
            if !c.sid.isEmpty { r["short_id"] = c.sid }
            tls["reality"] = r
        }
        o["tls"] = tls
        if c.net == "ws" {
            var t: [String: Any] = ["type": "ws"]
            if !c.path.isEmpty { t["path"] = c.path }
            if !c.hostHeader.isEmpty { t["headers"] = ["Host": c.hostHeader] }
            o["transport"] = t
        } else if c.net == "grpc" {
            var t: [String: Any] = ["type": "grpc"]
            if !c.service.isEmpty { t["service_name"] = c.service }
            o["transport"] = t
        }
        return o
    }

    private func writeConfig() -> URL? {
        let tags = channels.map { $0.tag }
        guard !tags.isEmpty else { return nil }
        let cfg: [String: Any] = [
            "log": ["level": "warn"],
            "experimental": [
                "clash_api": ["external_controller": "127.0.0.1:\(API_PORT)", "secret": settings.apiSecret],
                "cache_file": ["enabled": true,
                               "path": supportDir.appendingPathComponent("cache.db").path],
            ],
            "inbounds": [["type": "mixed", "tag": "in", "listen": "127.0.0.1",
                          "listen_port": PROXY_PORT]],
            "outbounds": [
                ["type": "selector", "tag": "proxy", "outbounds": ["auto"] + tags,
                 "default": "auto"] as [String: Any],
                ["type": "urltest", "tag": "auto", "outbounds": tags,
                 "url": "https://www.gstatic.com/generate_204", "interval": "3m",
                 "tolerance": 100] as [String: Any],
                ["type": "direct", "tag": "direct"],
            ] + channels.map(outboundDict),
            "route": ["final": "proxy",
                      "rules": [["ip_is_private": true, "outbound": "direct"]]],
        ]
        let url = supportDir.appendingPathComponent("singbox.json")
        guard let d = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        try? d.write(to: url)
        return url
    }

    /// только из q
    private func startLocked() {
        stopLocked()
        guard let bin = singboxPath else {
            lastError = "sing-box не найден — пересобери приложение (scripts/build-app.sh) или brew install sing-box"
            return
        }
        guard let cfg = writeConfig() else { lastError = "нет каналов — добавь подписку"; return }
        // осиротевший sing-box с нашим конфигом держит порты — убрать
        run("/usr/bin/pkill", ["-f", "sing-box run -c \(cfg.path)"], timeout: 5)
        usleep(300_000)
        let check = run(bin, ["check", "-c", cfg.path])
        if !check.isEmpty { lastError = "конфиг не прошёл проверку: \(check.prefix(200))"; log(lastError); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["run", "-c", cfg.path, "--disable-color"]
        let logFile = supportDir.appendingPathComponent("singbox.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: logFile) { p.standardOutput = h; p.standardError = h }
        expectStop = false
        p.terminationHandler = { [weak self] dead in
            guard let self else { return }
            self.q.async {
                // умер не актуальный процесс (его уже заменили) — игнорируем
                guard self.proc === dead else { return }
                self.running = false
                if !self.expectStop {
                    self.lastError = "sing-box упал (код \(dead.terminationStatus)) — перезапускаю"
                    log(self.lastError)
                    self.q.asyncAfter(deadline: .now() + 2) {
                        if self.proc === dead { self.startLocked(); self.changed() }
                    }
                }
                self.changed()
            }
        }
        do {
            try p.run()
            proc = p
            running = true
            lastError = ""
            selected = "auto"
            log("sing-box запущен, каналов: \(channels.count)")
        } catch {
            lastError = "не удалось запустить sing-box: \(error.localizedDescription)"
            log(lastError)
        }
    }

    private func stopLocked() {
        expectStop = true
        proc?.terminationHandler = nil
        proc?.terminate()
        proc = nil
        running = false
        externalIP = ""
        now = ""
    }

    func connect() { q.async { self.startLocked(); self.changed(); self.checkIP() } }
    func disconnect() { q.async { self.stopLocked(); self.changed() } }

    // ------------------------------------------------------------ clash API

    private func api(_ method: String, _ path: String, body: [String: Any]? = nil,
                     timeout: TimeInterval = 10) -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(API_PORT)\(path)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(settings.apiSecret)", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        var result: Data?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let r = resp as? HTTPURLResponse, (200..<300).contains(r.statusCode) { result = data ?? Data() }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 5)
        return result
    }

    func select(_ tag: String) {
        q.async {
            if self.api("PUT", "/proxies/proxy", body: ["name": tag]) != nil {
                self.selected = tag
                self.externalIP = ""
                self.changed()
                self.checkIP()
            }
        }
    }

    // ------------------------------------------------------------ подписка и проверка

    func refreshSubscription(then probeAfter: Bool = true) {
        q.async {
            let subs = self.settings.subscriptions.filter { $0.enabled }
            guard !subs.isEmpty else {
                self.lastError = "нет включённых списков — добавь в разделе «Списки»"
                self.changed(); return
            }
            self.lastSubRefresh = Date()
            var tags = Set<String>()
            var parsed: [Channel] = []
            var totalLinks = 0
            for (i, sub) in subs.enumerated() {
                self.busy = "качаю список \(i + 1)/\(subs.count): \(sub.name)…"; self.changed()
                let links = fetchSubscription(sub.url)
                totalLinks += links.count
                let before = parsed.count
                for l in links {
                    if let c = parseVless(l, existing: &tags, skipRU: self.settings.skipRU) {
                        parsed.append(c)
                    }
                }
                log("список '\(sub.name)': \(links.count) ссылок -> +\(parsed.count - before)")
            }
            self.busy = ""
            if parsed.isEmpty {
                self.lastError = "в списках не нашлось подходящих vless-ссылок (\(totalLinks) строк)"
                log(self.lastError); self.changed(); return
            }
            // слишком много каналов душат sing-box — равномерная выборка
            if parsed.count > MAX_CHANNELS {
                let step = Double(parsed.count) / Double(MAX_CHANNELS)
                parsed = (0..<MAX_CHANNELS).map { parsed[Int(Double($0) * step)] }
                log("каналов \(tags.count) — взял равномерно \(MAX_CHANNELS)")
            }
            self.channels = parsed
            self.delays = [:]
            self.saveChannels()
            self.lastError = ""
            log("итого: \(totalLinks) ссылок -> \(parsed.count) каналов")
            if self.running || probeAfter { self.startLocked() }
            self.changed()
            if probeAfter { self.probeLocked() }
        }
    }

    // ------------------------------------------------------------ управление списками

    func addSub(name: String, url: String) {
        q.async {
            guard !self.settings.subscriptions.contains(where: { $0.url == url }) else { return }
            self.settings.subscriptions.append(SubEntry(name: name, url: url))
            self.settings.save()
            self.changed()
            self.refreshSubscription()
        }
    }

    func removeSub(url: String) {
        q.async {
            self.settings.subscriptions.removeAll { $0.url == url }
            self.settings.save()
            self.changed()
        }
    }

    func toggleSub(url: String) {
        q.async {
            if let i = self.settings.subscriptions.firstIndex(where: { $0.url == url }) {
                self.settings.subscriptions[i].enabled.toggle()
                self.settings.save()
                self.changed()
            }
        }
    }

    func setSystemProxyFlag(_ on: Bool) {
        q.async {
            self.settings.systemProxyOn = on
            self.settings.save()
            self.changed()
        }
    }

    func probe() { q.async { self.probeLocked() } }

    /// только из q: групповой замер всех каналов, отсев мёртвых («наш принцип»)
    private func probeLocked() {
        guard running else { return }
        busy = "проверяю каналы…"; changed()
        // sing-box мог только что перезапуститься — дождаться API
        for _ in 0..<20 {
            if api("GET", "/version", timeout: 2) != nil { break }
            usleep(500_000)
        }
        // пнуть групповой тест; результаты сами лягут в history каждого прокси
        let u = "https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204"
        _ = api("GET", "/group/auto/delay?timeout=5000&url=\(u)", timeout: 15)
        // ждать, пока число живых стабилизируется (двa одинаковых замера подряд)
        var d: [String: Int] = [:]
        var last = -1, stable = 0
        for _ in 0..<18 {
            usleep(5_000_000)
            d = readDelaysLocked()
            if d.count == last && d.count > 0 {
                stable += 1
                if stable >= 2 { break }
            } else { stable = 0 }
            last = d.count
        }
        busy = ""
        delays = d
        let alive = channels.filter { d[$0.tag] != nil }
        let deadCount = channels.count - alive.count
        // защита как на роутере: если умерли все — это сбой интернета, не каналов
        if deadCount > 0 && !alive.isEmpty {
            channels = alive
            saveChannels()
            log("проверка: живых \(alive.count), удалено мёртвых \(deadCount)")
            startLocked()  // пересобрать конфиг без мёртвых
        } else {
            log("проверка: живых \(alive.count) из \(channels.count)")
        }
        lastError = ""
        refreshNowLocked()
        changed()
        checkIP()
        // мало живых — обновить подписку (кулдаун 10 мин);
        // но если замеров нет, а туннель работает — это сбой замера, не каналов
        if alive.isEmpty && !now.isEmpty { return }
        if alive.count < settings.minChannels,
           Date().timeIntervalSince(lastSubRefresh) > 600 {
            log("AUTO-HEAL живых \(alive.count) < \(settings.minChannels) — обновляю подписку")
            refreshSubscription()
        }
    }

    /// только из q: пинги всех каналов из history (их меряет сам urltest)
    private func readDelaysLocked() -> [String: Int] {
        guard let data = api("GET", "/proxies", timeout: 10),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proxies = obj["proxies"] as? [String: Any] else { return [:] }
        var d: [String: Int] = [:]
        for c in channels {
            guard let p = proxies[c.tag] as? [String: Any],
                  let hist = p["history"] as? [[String: Any]],
                  let lastEntry = hist.last else { continue }
            var ms = 0
            if let n = lastEntry["delay"] as? Int { ms = n }
            else if let n = lastEntry["delay"] as? Double { ms = Int(n) }
            if ms > 0 { d[c.tag] = ms }
        }
        return d
    }

    /// только из q: обновить, какой канал реально выбран
    private func refreshNowLocked() {
        if selected != "auto" { now = selected; return }
        if let d = api("GET", "/proxies/auto", timeout: 5),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let n = o["now"] as? String { now = n }
    }

    // ------------------------------------------------------------ watchdog

    func healthTick() {
        q.async {
            guard self.running else { return }
            let code = run("/usr/bin/curl",
                           ["-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "8",
                            "-x", "socks5h://127.0.0.1:\(PROXY_PORT)",
                            "https://www.gstatic.com/generate_204"], timeout: 12)
            if code == "204" {
                let hadFails = self.failCount != 0
                self.failCount = 0
                self.refreshNowLocked()
                if hadFails { self.changed() }
                if self.externalIP.isEmpty { self.checkIP() }
                self.changed()
                return
            }
            self.failCount += 1
            log("watchdog: туннель не отвечает (\(self.failCount))")
            if self.failCount == 2 {
                // пнуть urltest — пусть перевыберет живой канал
                _ = self.api("GET", "/group/auto/delay?timeout=5000&url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204", timeout: 60)
            } else if self.failCount >= 4, Date().timeIntervalSince(self.lastSubRefresh) > 600 {
                self.failCount = 0
                log("AUTO-HEAL связь пропала — обновляю подписку")
                self.refreshSubscription()
            }
            self.changed()
        }
    }

    private func checkIP() {
        q.async {
            guard self.running else { return }
            let ip = run("/usr/bin/curl",
                         ["-s", "-m", "8", "-x", "socks5h://127.0.0.1:\(PROXY_PORT)",
                          "https://api.ipify.org"], timeout: 12)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !ip.isEmpty && ip.count < 46 { self.externalIP = ip }
            self.refreshNowLocked()
            self.changed()
        }
    }
}
