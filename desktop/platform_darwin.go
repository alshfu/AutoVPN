//go:build darwin

package main

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

const singboxBinName = "sing-box"
const singboxInstallHint = "brew install sing-box / пересобери с fetch-singbox.sh"

var singboxCandidates = []string{
	"/opt/homebrew/bin/sing-box", "/opt/homebrew/opt/sing-box/bin/sing-box",
	"/usr/local/bin/sing-box",
}

func hideWindow(cmd *exec.Cmd) {}

func activeService() string {
	if svc := serviceForDefaultRoute(); svc != "" && !isVirtualService(svc) {
		return svc
	}
	if svc := firstLivePhysicalService(); svc != "" {
		return svc
	}
	return serviceForDefaultRoute()
}

func serviceForDefaultRoute() string {
	out, _ := exec.Command("/sbin/route", "-n", "get", "default").Output()
	dev := ""
	for _, l := range strings.Split(string(out), "\n") {
		l = strings.TrimSpace(l)
		if strings.HasPrefix(l, "interface:") {
			dev = strings.TrimSpace(strings.TrimPrefix(l, "interface:"))
		}
	}
	if dev == "" {
		return ""
	}
	out, _ = exec.Command("/usr/sbin/networksetup", "-listallhardwareports").Output()
	lines := strings.Split(string(out), "\n")
	for i, l := range lines {
		if strings.HasPrefix(l, "Device: ") && strings.TrimPrefix(l, "Device: ") == dev && i > 0 {
			return strings.TrimPrefix(lines[i-1], "Hardware Port: ")
		}
	}
	return ""
}

func firstLivePhysicalService() string {
	type pair struct{ name, device string }
	out, _ := exec.Command("/usr/sbin/networksetup", "-listallhardwareports").Output()
	var pairs []pair
	last := ""
	for _, l := range strings.Split(string(out), "\n") {
		l = strings.TrimSpace(l)
		if strings.HasPrefix(l, "Hardware Port:") {
			last = strings.TrimSpace(strings.TrimPrefix(l, "Hardware Port:"))
		} else if strings.HasPrefix(l, "Device:") && last != "" {
			pairs = append(pairs, pair{last, strings.TrimSpace(strings.TrimPrefix(l, "Device:"))})
			last = ""
		}
	}
	prefer := []string{"Wi-Fi", "Ethernet", "USB 10/100/1000 LAN", "USB 10/100 LAN"}
	for _, want := range prefer {
		for _, p := range pairs {
			if p.name == want && interfaceHasIP(p.device) {
				return p.name
			}
		}
	}
	for _, p := range pairs {
		if strings.HasPrefix(p.device, "en") && interfaceHasIP(p.device) && !isVirtualService(p.name) {
			return p.name
		}
	}
	for _, p := range pairs {
		if p.name == "Wi-Fi" {
			return p.name
		}
	}
	return ""
}

func interfaceHasIP(device string) bool {
	out, err := exec.Command("/usr/sbin/ipconfig", "getifaddr", device).Output()
	return err == nil && strings.TrimSpace(string(out)) != ""
}

func isVirtualService(name string) bool {
	n := strings.ToLower(name)
	for _, k := range []string{"v2ray", "v2box", "tailscale", "utun", "vpn", "wireguard", "tunnel", "cisco", "l2tp"} {
		if strings.Contains(n, k) {
			return true
		}
	}
	return false
}

func setSystemProxy(on bool, proxyPort int) error {
	svc := activeService()
	if svc == "" {
		return fmt.Errorf("не нашёл активный сетевой сервис")
	}
	if on {
		if err := exec.Command("/usr/sbin/networksetup", "-setsocksfirewallproxy", svc,
			"127.0.0.1", strconv.Itoa(proxyPort)).Run(); err != nil {
			return err
		}
		return exec.Command("/usr/sbin/networksetup", "-setsocksfirewallproxystate", svc, "on").Run()
	}
	return exec.Command("/usr/sbin/networksetup", "-setsocksfirewallproxystate", svc, "off").Run()
}

func setAutostart(on bool) error {
	return fmt.Errorf("на macOS используй нативное приложение AutoVPN.app")
}

func isAutostartOn() bool { return false }

func openBrowser(u string) {
	exec.Command("/usr/bin/open", u).Start()
}
