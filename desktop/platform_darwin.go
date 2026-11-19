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
