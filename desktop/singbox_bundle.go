package main

import (
	"embed"
	"os"
	"path/filepath"
	"strings"
)

// Бинарник кладётся сюда scripts/fetch-singbox.sh перед релизом.
// Без него (локальная сборка) — ищем системный sing-box.
//
//go:embed all:third_party
var thirdPartyFS embed.FS

const bundledSingboxVersionFile = "sing-box.version"

// ensureBundledSingbox извлекает встроенный sing-box в supportDir/bin/, если он есть.
// Возвращает путь или "".
func ensureBundledSingbox() string {
	data, name, ver, ok := readEmbeddedSingbox()
	if !ok {
		return ""
	}
	dir := filepath.Join(supportDir, "bin")
	dst := filepath.Join(dir, name)
	marker := filepath.Join(dir, bundledSingboxVersionFile)

	needWrite := true
	if st, err := os.Stat(dst); err == nil && st.Size() == int64(len(data)) {
		if b, err := os.ReadFile(marker); err == nil && strings.TrimSpace(string(b)) == ver {
			needWrite = false
		}
	}
	if needWrite {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return ""
		}
		tmp := dst + ".tmp"
		if err := os.WriteFile(tmp, data, 0o755); err != nil {
			return ""
		}
		if err := os.Rename(tmp, dst); err != nil {
			os.Remove(tmp)
			return ""
		}
		_ = os.WriteFile(marker, []byte(ver+"\n"), 0o644)
		if lic, err := thirdPartyFS.ReadFile("third_party/sing-box-LICENSE"); err == nil {
			_ = os.WriteFile(filepath.Join(dir, "sing-box-LICENSE"), lic, 0o644)
		}
	}
	return dst
}

func readEmbeddedSingbox() (data []byte, name, version string, ok bool) {
	name = singboxBinName
	data, err := thirdPartyFS.ReadFile("third_party/" + name)
	if err != nil || len(data) < 1024 {
		return nil, "", "", false
	}
	version = "unknown"
	if b, err := thirdPartyFS.ReadFile("third_party/" + bundledSingboxVersionFile); err == nil {
		version = strings.TrimSpace(string(b))
	}
	return data, name, version, true
}

func siblingSingbox() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	// на macOS Executable может быть через symlink
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	p := filepath.Join(filepath.Dir(exe), singboxBinName)
	if st, err := os.Stat(p); err == nil && !st.IsDir() {
		return p
	}
	return ""
}
