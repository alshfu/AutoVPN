//go:build linux

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
)

const singboxBinName = "sing-box"
const singboxInstallHint = "см. https://sing-box.sagernet.org/installation/package-managers/"

var singboxCandidates = []string{
	"/usr/local/bin/sing-box", "/usr/bin/sing-box", "/opt/sing-box/sing-box",
}

func hideWindow(cmd *exec.Cmd) {}

// системный прокси: GNOME через gsettings, иначе подсказка
func setSystemProxy(on bool, proxyPort int) error {
	if _, err := exec.LookPath("gsettings"); err != nil {
		return fmt.Errorf("автонастройка только для GNOME; вручную: export all_proxy=socks5h://127.0.0.1:%d", proxyPort)
	}
	if on {
		cmds := [][]string{
			{"set", "org.gnome.system.proxy.socks", "host", "127.0.0.1"},
			{"set", "org.gnome.system.proxy.socks", "port", strconv.Itoa(proxyPort)},
			{"set", "org.gnome.system.proxy", "mode", "manual"},
		}
		for _, a := range cmds {
			if out, err := exec.Command("gsettings", a...).CombinedOutput(); err != nil {
				return fmt.Errorf("gsettings: %s", firstN(string(out), 120))
			}
		}
		return nil
	}
	out, err := exec.Command("gsettings", "set", "org.gnome.system.proxy", "mode", "none").CombinedOutput()
	if err != nil {
		return fmt.Errorf("gsettings: %s", firstN(string(out), 120))
	}
	return nil
}

func setAutostart(on bool) error {
	dir := filepath.Join(os.Getenv("HOME"), ".config", "autostart")
	p := filepath.Join(dir, "autovpn.desktop")
	if !on {
		os.Remove(p)
		return nil
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	os.MkdirAll(dir, 0o755)
	return os.WriteFile(p, []byte("[Desktop Entry]\nType=Application\nName=AutoVPN\nExec="+
		exe+" -no-browser\nX-GNOME-Autostart-enabled=true\n"), 0o644)
}

func isAutostartOn() bool {
	_, err := os.Stat(filepath.Join(os.Getenv("HOME"), ".config", "autostart", "autovpn.desktop"))
	return err == nil
}

func openBrowser(u string) {
	exec.Command("xdg-open", u).Start()
}
