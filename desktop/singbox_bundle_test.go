package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestEnsureBundledSingbox(t *testing.T) {
	data, name, ver, ok := readEmbeddedSingbox()
	if !ok {
		t.Skip("sing-box not embedded — run ../scripts/fetch-singbox.sh first")
	}
	if len(data) < 1024 {
		t.Fatal("embedded data too small")
	}
	t.Logf("embedded %s version=%s size=%d", name, ver, len(data))

	dir := t.TempDir()
	dst := filepath.Join(dir, name)
	if err := os.WriteFile(dst, data, 0o755); err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command(dst, "version").CombinedOutput()
	if err != nil {
		t.Fatalf("version: %v %s", err, out)
	}
	t.Log(string(out))
}
