//go:build windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"unsafe"
)

const singboxBinName = "sing-box.exe"
const singboxInstallHint = "winget install SagerNet.sing-box / положи sing-box.exe рядом / пересобери с fetch-singbox.sh"

var singboxCandidates = []string{
	`C:\sing-box\sing-box.exe`,
	`C:\Program Files\sing-box\sing-box.exe`,
	filepath.Join(os.Getenv("LOCALAPPDATA"), `Microsoft\WinGet\Links\sing-box.exe`),
	filepath.Join(os.Getenv("USERPROFILE"), `scoop\shims\sing-box.exe`),
	filepath.Join(exeDir(), "sing-box.exe"),
}

func exeDir() string {
	p, err := os.Executable()
	if err != nil {
		return "."
	}
	return filepath.Dir(p)
}

func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
}

// системный прокси через реестр WinINET + уведомление приложений
func setSystemProxy(on bool, proxyPort int) error {
	key := `HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings`
	var args [][]string
	if on {
		args = [][]string{
			{"add", key, "/v", "ProxyEnable", "/t", "REG_DWORD", "/d", "1", "/f"},
			{"add", key, "/v", "ProxyServer", "/t", "REG_SZ", "/d", fmt.Sprintf("127.0.0.1:%d", proxyPort), "/f"},
			{"add", key, "/v", "ProxyOverride", "/t", "REG_SZ", "/d", "<local>", "/f"},
		}
	} else {
		args = [][]string{{"add", key, "/v", "ProxyEnable", "/t", "REG_DWORD", "/d", "0", "/f"}}
	}
	for _, a := range args {
		cmd := exec.Command("reg", a...)
		hideWindow(cmd)
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("reg %v: %s", err, firstN(string(out), 120))
		}
	}
	// INTERNET_OPTION_SETTINGS_CHANGED + INTERNET_OPTION_REFRESH
	wininet := syscall.NewLazyDLL("wininet.dll")
	setOpt := wininet.NewProc("InternetSetOptionW")
	setOpt.Call(0, 39, 0, 0)
	setOpt.Call(0, 37, 0, 0)
	_ = unsafe.Pointer(nil)
	return nil
}

func setAutostart(on bool) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	key := `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
	var cmd *exec.Cmd
	if on {
		cmd = exec.Command("reg", "add", key, "/v", "AutoVPN", "/t", "REG_SZ",
			"/d", `"`+exe+`" -no-browser`, "/f")
	} else {
		cmd = exec.Command("reg", "delete", key, "/v", "AutoVPN", "/f")
	}
	hideWindow(cmd)
	out, err := cmd.CombinedOutput()
	if err != nil && on {
		return fmt.Errorf("reg: %s", firstN(string(out), 120))
	}
	return nil
}

func isAutostartOn() bool {
	cmd := exec.Command("reg", "query",
		`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, "/v", "AutoVPN")
	hideWindow(cmd)
	return cmd.Run() == nil
}

func openBrowser(u string) {
	cmd := exec.Command("rundll32", "url.dll,FileProtocolHandler", u)
	hideWindow(cmd)
	cmd.Start()
}
