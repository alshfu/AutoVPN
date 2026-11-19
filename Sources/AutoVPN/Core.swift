import Foundation

// ---------------------------------------------------------------- файлы/настройки

let supportDir: URL = {
    let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AutoVPN")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}()

func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    let f = supportDir.appendingPathComponent("autovpn.log")
    if let h = try? FileHandle(forWritingTo: f) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.data(using: .utf8)!.write(to: f)
    }
}

struct SubEntry: Codable, Equatable, Identifiable {
    var id: String { url }
    var name: String
    var url: String
    var enabled: Bool = true
}

struct Preset {
    let name: String
    let url: String
    let note: String
}

// топ-5 публичных списков (проверены 2026-11-19)
let topPresets: [Preset] = [
    Preset(name: "4Diana",
           url: "https://raw.githubusercontent.com/EEvanescence/4Diana/main/By-protocol/vless.txt",
           note: "~750 vless, стабильный"),
    Preset(name: "Barry Far",
           url: "https://raw.githubusercontent.com/barry-far/V2ray-Config/main/Splitted-By-Protocol/vless.txt",
           note: "~6000, классика"),
    Preset(name: "VLESS Russia",
           url: "https://raw.githubusercontent.com/kort0881/vpn-vless-configs-russia/main/output/vless.txt",
           note: "~6000, проверяются для РФ"),
    Preset(name: "По Грибы",
           url: "https://raw.githubusercontent.com/histeenn/VLESS-PO-GRIBI/main/deploy/sub.txt",
           note: "~2000, смешанный"),
    Preset(name: "Whitelist bypass",
           url: "https://raw.githubusercontent.com/zieng2/wl/main/vless_universal.txt",
           note: "~100, обход белых списков"),
]

struct Settings: Codable {
    var subscriptions: [SubEntry] = []
    var minChannels: Int = 4
    var skipRU: Bool = true
    var apiSecret: String = UUID().uuidString
    var systemProxyOn: Bool = false

    enum CodingKeys: String, CodingKey {
        case subscriptions, subscription, minChannels, skipRU, apiSecret, systemProxyOn
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subscriptions = (try? c.decode([SubEntry].self, forKey: .subscriptions)) ?? []
        // миграция со старого формата с одной подпиской
        if subscriptions.isEmpty,
           let old = try? c.decode(String.self, forKey: .subscription), !old.isEmpty {
            let name = topPresets.first { $0.url == old }?.name ?? "Моя подписка"
            subscriptions = [SubEntry(name: name, url: old)]
        }
        minChannels = (try? c.decode(Int.self, forKey: .minChannels)) ?? 4
        skipRU = (try? c.decode(Bool.self, forKey: .skipRU)) ?? true
        apiSecret = (try? c.decode(String.self, forKey: .apiSecret)) ?? UUID().uuidString
        systemProxyOn = (try? c.decode(Bool.self, forKey: .systemProxyOn)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(subscriptions, forKey: .subscriptions)
        try c.encode(minChannels, forKey: .minChannels)
        try c.encode(skipRU, forKey: .skipRU)
        try c.encode(apiSecret, forKey: .apiSecret)
        try c.encode(systemProxyOn, forKey: .systemProxyOn)
    }

    static func load() -> Settings {
        if let d = try? Data(contentsOf: supportDir.appendingPathComponent("settings.json")),
           let s = try? JSONDecoder().decode(Settings.self, from: d) { return s }
        return Settings()
    }

    func save() {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? e.encode(self) {
            try? d.write(to: supportDir.appendingPathComponent("settings.json"))
        }
    }
}

// ---------------------------------------------------------------- модель канала

struct Channel: Codable, Equatable {
    var tag = "", server = "", uuid = "", flow = "", security = "", sni = ""
    var pbk = "", sid = "", fp = "", net = "", path = "", hostHeader = "", service = ""
    var port = 0
}

let ruTagRegex = try! NSRegularExpression(pattern: "(^|[-_ ])RU([-_ ]|$)", options: [.caseInsensitive])

func isRUTag(_ tag: String) -> Bool {
    ruTagRegex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) != nil
}

func parseVless(_ link: String, existing: inout Set<String>, skipRU: Bool) -> Channel? {
    guard link.hasPrefix("vless://"), let comp = URLComponents(string: link),
          let host = comp.host, !host.isEmpty, let port = comp.port,
          let uuid = comp.user, !uuid.isEmpty else { return nil }
    var q: [String: String] = [:]
    for item in comp.queryItems ?? [] { q[item.name] = item.value ?? "" }
    let sec = (q["security"] ?? "none").lowercased()
    // те же правила, что в панели роутера: без tls/reality не берём
    guard sec == "tls" || sec == "reality" else { return nil }
    if sec == "reality" && (q["pbk"] ?? "").isEmpty { return nil }

    var c = Channel()
    c.server = host
    c.port = port
    c.uuid = uuid
    c.security = sec
    // sing-box знает только xtls-rprx-vision; варианты типа -udp443 нормализуем, мусор отбрасываем
    let rawFlow = q["flow"] ?? ""
    c.flow = rawFlow.hasPrefix("xtls-rprx-vision") ? "xtls-rprx-vision" : ""
    c.sni = q["sni"] ?? ""
    c.pbk = q["pbk"] ?? ""
    c.sid = q["sid"] ?? ""
    // sing-box принимает только известные uTLS-отпечатки
    let knownFP: Set<String> = ["chrome", "firefox", "edge", "safari", "360", "qq",
                                "ios", "android", "random", "randomized"]
    let fp = (q["fp"] ?? "").lowercased()
    c.fp = knownFP.contains(fp) ? fp : ""
    c.net = (q["type"] ?? "tcp").lowercased()
    c.path = q["path"] ?? ""
    c.hostHeader = q["host"] ?? ""
    c.service = q["serviceName"] ?? ""

    var tag = (comp.fragment ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if tag.isEmpty { tag = "\(host):\(port)" }
    tag = tag.replacingOccurrences(of: "\"", with: "")
    if skipRU && isRUTag(tag) { return nil }
    var unique = tag
    var n = 2
    while existing.contains(unique) { unique = "\(tag)-\(n)"; n += 1 }
    existing.insert(unique)
    c.tag = unique
    return c
}

// ---------------------------------------------------------------- helpers

@discardableResult
func run(_ cmd: String, _ args: [String], timeout: TimeInterval = 30) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cmd)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return "" }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(50_000) }
    if p.isRunning { p.terminate() }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

func httpGet(_ urlString: String, timeout: TimeInterval = 20, headers: [String: String] = [:]) -> Data? {
    guard let url = URL(string: urlString) else { return nil }
    var req = URLRequest(url: url, timeoutInterval: timeout)
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    var result: Data?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        if let r = resp as? HTTPURLResponse, (200..<300).contains(r.statusCode) { result = data }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 5)
    return result
}

func fetchSubscription(_ urlString: String) -> [String] {
    guard let data = httpGet(urlString, timeout: 30),
          var text = String(data: data, encoding: .utf8) else { return [] }
    if !text.contains("://") {  // base64-подписка
        var b = text.filter { !$0.isWhitespace }
        while b.count % 4 != 0 { b += "=" }
        if let d = Data(base64Encoded: b), let t = String(data: d, encoding: .utf8) { text = t }
    }
    return text.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("vless://") }
}
