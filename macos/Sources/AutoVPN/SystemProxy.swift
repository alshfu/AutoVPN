import Foundation

enum SystemProxy {
    /// имя активного сетевого сервиса ("Wi-Fi" и т.п.)
    static func activeService() -> String? {
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

    @discardableResult
    static func set(on: Bool) -> Bool {
        guard let svc = activeService() else { return false }
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
}
