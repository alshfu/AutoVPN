package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"crypto/rand"
)

// ---------------------------------------------------------------- файлы/настройки

var supportDir = func() string {
	base, err := os.UserConfigDir()
	if err != nil {
		base = "."
	}
	d := filepath.Join(base, "AutoVPN")
	if dirOverride := os.Getenv("AUTOVPN_DIR"); dirOverride != "" {
		d = dirOverride
	}
	os.MkdirAll(d, 0o755)
	return d
}()

func logf(format string, a ...any) {
	line := time.Now().UTC().Format(time.RFC3339) + " " + fmt.Sprintf(format, a...) + "\n"
	f, err := os.OpenFile(filepath.Join(supportDir, "autovpn.log"),
		os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err == nil {
		f.WriteString(line)
		f.Close()
	}
	logRing.add(strings.TrimRight(line, "\n"))
}

type SubEntry struct {
	Name    string `json:"name"`
	URL     string `json:"url"`
	Enabled bool   `json:"enabled"`
}

type Preset struct {
	Name string `json:"name"`
	URL  string `json:"url"`
	Note string `json:"note"`
}

// топ-5 публичных списков (проверены 2026-11-19)
var topPresets = []Preset{
	{"4Diana", "https://raw.githubusercontent.com/EEvanescence/4Diana/main/By-protocol/vless.txt", "~750 vless, стабильный"},
	{"Barry Far", "https://raw.githubusercontent.com/barry-far/V2ray-Config/main/Splitted-By-Protocol/vless.txt", "~6000, классика"},
	{"VLESS Russia", "https://raw.githubusercontent.com/kort0881/vpn-vless-configs-russia/main/output/vless.txt", "~6000, проверяются для РФ"},
	{"По Грибы", "https://raw.githubusercontent.com/histeenn/VLESS-PO-GRIBI/main/deploy/sub.txt", "~2000, смешанный"},
	{"Whitelist bypass", "https://raw.githubusercontent.com/zieng2/wl/main/vless_universal.txt", "~100, обход белых списков"},
}

type Settings struct {
	Subscriptions []SubEntry `json:"subscriptions"`
	MinChannels   int        `json:"minChannels"`
	SkipRU        bool       `json:"skipRU"`
	APISecret     string     `json:"apiSecret"`
	SystemProxyOn bool       `json:"systemProxyOn"`
	SingboxPath   string     `json:"singboxPath,omitempty"`
	ProxyPort     int        `json:"proxyPort"`
	APIPort       int        `json:"apiPort"`
	WebPort       int        `json:"webPort"`
}

func randomSecret() string {
	b := make([]byte, 16)
	rand.Read(b)
	return fmt.Sprintf("%x", b)
}

func defaultSettings() Settings {
	return Settings{
		MinChannels: 4, SkipRU: true, APISecret: randomSecret(),
		ProxyPort: 2080, APIPort: 9092, WebPort: 2082,
	}
}

func loadSettings() Settings {
	s := defaultSettings()
	d, err := os.ReadFile(filepath.Join(supportDir, "settings.json"))
	if err == nil {
		json.Unmarshal(d, &s)
	}
	if s.MinChannels <= 0 {
		s.MinChannels = 4
	}
	if s.APISecret == "" {
		s.APISecret = randomSecret()
	}
	if s.ProxyPort == 0 {
		s.ProxyPort = 2080
	}
	if s.APIPort == 0 {
		s.APIPort = 9092
	}
	if s.WebPort == 0 {
		s.WebPort = 2082
	}
	return s
}

func (s Settings) save() {
	d, err := json.MarshalIndent(s, "", "  ")
	if err == nil {
		os.WriteFile(filepath.Join(supportDir, "settings.json"), d, 0o600)
	}
}

// ---------------------------------------------------------------- модель канала

type Channel struct {
	Tag        string `json:"tag"`
	Server     string `json:"server"`
	UUID       string `json:"uuid"`
	Flow       string `json:"flow"`
	Security   string `json:"security"`
	SNI        string `json:"sni"`
	PBK        string `json:"pbk"`
	SID        string `json:"sid"`
	FP         string `json:"fp"`
	Net        string `json:"net"`
	Path       string `json:"path"`
	HostHeader string `json:"hostHeader"`
	Service    string `json:"service"`
	Port       int    `json:"port"`
}

var ruTagRegex = regexp.MustCompile(`(?i)(^|[-_ ])RU([-_ ]|$)`)

var knownFP = map[string]bool{
	"chrome": true, "firefox": true, "edge": true, "safari": true, "360": true,
	"qq": true, "ios": true, "android": true, "random": true, "randomized": true,
}

func parseVless(link string, existing map[string]bool, skipRU bool) *Channel {
	if !strings.HasPrefix(link, "vless://") {
		return nil
	}
	u, err := url.Parse(link)
	if err != nil || u.User == nil {
		return nil
	}
	host := u.Hostname()
	port, _ := strconv.Atoi(u.Port())
	uuid := u.User.Username()
	if host == "" || port == 0 || uuid == "" {
		return nil
	}
	q := u.Query()
	sec := strings.ToLower(q.Get("security"))
	// те же правила, что на роутере и в macOS-клиенте: без tls/reality не берём
	if sec != "tls" && sec != "reality" {
		return nil
	}
	if sec == "reality" && q.Get("pbk") == "" {
		return nil
	}
	c := &Channel{Server: host, Port: port, UUID: uuid, Security: sec}
	// sing-box знает только xtls-rprx-vision; варианты типа -udp443 нормализуем
	if strings.HasPrefix(q.Get("flow"), "xtls-rprx-vision") {
		c.Flow = "xtls-rprx-vision"
	}
	c.SNI = q.Get("sni")
	c.PBK = q.Get("pbk")
	c.SID = q.Get("sid")
	if fp := strings.ToLower(q.Get("fp")); knownFP[fp] {
		c.FP = fp
	}
	c.Net = strings.ToLower(q.Get("type"))
	if c.Net == "" {
		c.Net = "tcp"
	}
	c.Path = q.Get("path")
	c.HostHeader = q.Get("host")
	c.Service = q.Get("serviceName")

	tag := strings.TrimSpace(u.Fragment)
	if tag == "" {
		tag = fmt.Sprintf("%s:%d", host, port)
	}
	tag = strings.ReplaceAll(tag, `"`, "")
	if skipRU && ruTagRegex.MatchString(tag) {
		return nil
	}
	unique := tag
	for n := 2; existing[unique]; n++ {
		unique = fmt.Sprintf("%s-%d", tag, n)
	}
	existing[unique] = true
	c.Tag = unique
	return c
}

// ---------------------------------------------------------------- helpers

var directClient = &http.Client{Timeout: 35 * time.Second}

func fetchSubscription(u string) []string {
	resp, err := directClient.Get(u)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 50<<20))
	if err != nil {
		return nil
	}
	text := string(data)
	if !strings.Contains(text, "://") { // base64-подписка
		b := strings.Join(strings.Fields(text), "")
		for len(b)%4 != 0 {
			b += "="
		}
		if d, err := base64.StdEncoding.DecodeString(b); err == nil {
			text = string(d)
		}
	}
	var out []string
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "vless://") {
			out = append(out, line)
		}
	}
	return out
}

// кольцевой буфер последних строк лога для веб-панели
type ring struct {
	mu    sync.Mutex
	lines []string
}

var logRing = &ring{}

func (r *ring) add(s string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.lines = append(r.lines, s)
	if len(r.lines) > 300 {
		r.lines = r.lines[len(r.lines)-300:]
	}
}

func (r *ring) get() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string{}, r.lines...)
}

var platformName = runtime.GOOS
