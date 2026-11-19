import Foundation

enum SystemProxy {
    /// Физические сервисы, на которые имеет смысл вешать SOCKS.
    /// VPN/utun в default route ломает старую логику — тогда берём Wi‑Fi/Ethernet.
    /// имя активного сетевого сервиса ("Wi-Fi" и т.п.)
    static func activeService() -> String? {
        if let svc = serviceForDefaultRoute(), !isVirtualName(svc) {
            return svc
        }
        // VPN/utun держит default route — вешаем прокси на живой физический линк
        if let svc = firstLivePhysicalService() {
            log("системный прокси: default route на VPN/utun → использую \(svc)")
            return svc
        }
        return serviceForDefaultRoute()
    }

    /// Есть ли чужой VPN (V2Box / v2RayTun / …), который перехватывает default route.
    static func conflictingVPN() -> String? {
        let out = run("/usr/sbin/scutil", ["--nc", "list"], timeout: 5)
        for raw in out.split(whereSeparator: \.isNewline) {
            let s = String(raw)
            // "* (Connected) ... "V2BOX" ..."
            guard s.contains("(Connected)") else { continue }
            if let name = vpnDisplayName(s) { return name }
        }
        // fallback по интерфейсу default route
        let route = run("/sbin/route", ["-n", "get", "default"], timeout: 5)
        if let line = route.split(whereSeparator: \.isNewline).first(where: { $0.contains("interface:") }) {
            let dev = line.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if dev.hasPrefix("utun") || dev.hasPrefix("tun") || dev.hasPrefix("ipsec") {
                return dev
            }
        }
        return nil
    }

    @discardableResult
    static func set(on: Bool) -> Bool {
        guard let svc = activeService() else {
            log("системный прокси: не нашёл сетевой сервис")
            return false
        }
        if on {
            run("/usr/sbin/networksetup", ["-setsocksfirewallproxy", svc, "127.0.0.1", "\(PROXY_PORT)"], timeout: 10)
            run("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", svc, "on"], timeout: 10)
        } else {
            run("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", svc, "off"], timeout: 10)
        }
        let state = run("/usr/sbin/networksetup", ["-getsocksfirewallproxy", svc], timeout: 10)
        let enabled = state.contains("Enabled: Yes")
        log("системный прокси (\(svc)): \(enabled ? "вкл" : "выкл")")
        return enabled == on
    }

    // MARK: - helpers

    private static func serviceForDefaultRoute() -> String? {
        let route = run("/sbin/route", ["-n", "get", "default"], timeout: 5)
        guard let line = route.split(whereSeparator: \.isNewline).first(where: { $0.contains("interface:") }),
              let dev = line.split(separator: ":").last.map({ $0.trimmingCharacters(in: .whitespaces) })
        else { return nil }
        let hw = run("/usr/sbin/networksetup", ["-listallhardwareports"], timeout: 10)
        var lastPort = ""
        for raw in hw.split(whereSeparator: \.isNewline) {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("Hardware Port:") {
                lastPort = s.dropFirst("Hardware Port:".count).trimmingCharacters(in: .whitespaces)
            } else if s == "Device: \(dev)" {
                return lastPort
            }
        }
        return nil
    }

    private static func firstLivePhysicalService() -> String? {
        let hw = run("/usr/sbin/networksetup", ["-listallhardwareports"], timeout: 10)
        var pairs: [(name: String, device: String)] = []
        var lastPort = ""
        for raw in hw.split(whereSeparator: \.isNewline) {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("Hardware Port:") {
                lastPort = s.dropFirst("Hardware Port:".count).trimmingCharacters(in: .whitespaces)
            } else if s.hasPrefix("Device:"), !lastPort.isEmpty {
                let dev = s.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)
                pairs.append((lastPort, String(dev)))
                lastPort = ""
            }
        }
        // сначала известные имена, потом любой en* с адресом
        for want in ["Wi-Fi", "Ethernet", "USB 10/100/1000 LAN", "USB 10/100 LAN"] {
            if let p = pairs.first(where: { $0.name == want }), interfaceHasIP(p.device) {
                return p.name
            }
        }
        for p in pairs where p.device.hasPrefix("en") && interfaceHasIP(p.device) {
            if !isVirtualName(p.name) { return p.name }
        }
        return pairs.first(where: { $0.name == "Wi-Fi" })?.name
    }

    private static func interfaceHasIP(_ device: String) -> Bool {
        let out = run("/usr/sbin/ipconfig", ["getifaddr", device], timeout: 3)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !out.isEmpty
    }

    private static func isVirtualName(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("v2ray") || n.contains("v2box") || n.contains("tailscale")
            || n.contains("utun") || n.contains("vpn") || n.contains("wireguard")
            || n.contains("tunnel") || n.contains("cisco") || n.contains("l2tp")
    }

    private static func vpnDisplayName(_ scutilLine: String) -> String? {
        // scutil --nc list: * (Connected)   UUID VPN (plugin) "Name" ...
        if let r = scutilLine.range(of: "\"([^\"]+)\"", options: .regularExpression) {
            let raw = String(scutilLine[r])
            return String(raw.dropFirst().dropLast())
        }
        return nil
    }
}
