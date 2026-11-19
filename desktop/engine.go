package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const maxChannels = 400

// Принцип: подписка -> отсев -> sing-box -> самый быстрый -> самолечение.
type Engine struct {
	mu sync.Mutex

	settings       Settings
	channels       []Channel
	delays         map[string]int // tag -> мс (живые после последней проверки)
	selected       string         // что выбрано в селекторе
	running        bool
	busy           string
	externalIP     string
	lastError      string
	failCount      int
	lastSubRefresh time.Time
	now            string // канал, который реально выбран сейчас
	probing        bool

	proc       *exec.Cmd
	expectStop bool
}

func newEngine() *Engine {
	e := &Engine{settings: loadSettings(), delays: map[string]int{}, selected: "auto"}
	if d, err := os.ReadFile(filepath.Join(supportDir, "channels.json")); err == nil {
		json.Unmarshal(d, &e.channels)
	}
	return e
}

func (e *Engine) saveChannelsLocked() {
	if d, err := json.Marshal(e.channels); err == nil {
		os.WriteFile(filepath.Join(supportDir, "channels.json"), d, 0o644)
	}
}

// ------------------------------------------------------------ sing-box

func (e *Engine) singboxPath() string {
	if e.settings.SingboxPath != "" {
		return e.settings.SingboxPath
	}
	if p, err := exec.LookPath(singboxBinName); err == nil {
		return p
	}
	for _, p := range singboxCandidates {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}

func (e *Engine) outboundDict(c Channel) map[string]any {
	o := map[string]any{"type": "vless", "tag": c.Tag, "server": c.Server,
		"server_port": c.Port, "uuid": c.UUID}
	if strings.HasPrefix(c.Flow, "xtls-rprx-vision") {
		o["flow"] = "xtls-rprx-vision"
	}
	tls := map[string]any{"enabled": true}
	if c.SNI != "" {
		tls["server_name"] = c.SNI
	}
	// reality без uTLS sing-box не принимает
	fp := c.FP
	if fp == "" && c.Security == "reality" {
		fp = "chrome"
	}
	if fp != "" {
		tls["utls"] = map[string]any{"enabled": true, "fingerprint": fp}
	}
	if c.Security == "reality" {
		r := map[string]any{"enabled": true, "public_key": c.PBK}
		if c.SID != "" {
			r["short_id"] = c.SID
		}
		tls["reality"] = r
	}
	o["tls"] = tls
	if c.Net == "ws" {
		t := map[string]any{"type": "ws"}
		if c.Path != "" {
			t["path"] = c.Path
		}
		if c.HostHeader != "" {
			t["headers"] = map[string]any{"Host": c.HostHeader}
		}
		o["transport"] = t
	} else if c.Net == "grpc" {
		t := map[string]any{"type": "grpc"}
		if c.Service != "" {
			t["service_name"] = c.Service
		}
		o["transport"] = t
	}
	return o
}

func (e *Engine) writeConfigLocked() string {
	if len(e.channels) == 0 {
		return ""
	}
	tags := make([]any, 0, len(e.channels))
	outs := []any{}
	for _, c := range e.channels {
		tags = append(tags, c.Tag)
		outs = append(outs, e.outboundDict(c))
	}
	cfg := map[string]any{
		"log": map[string]any{"level": "warn"},
		"experimental": map[string]any{
			"clash_api": map[string]any{
				"external_controller": fmt.Sprintf("127.0.0.1:%d", e.settings.APIPort),
				"secret":              e.settings.APISecret,
			},
			"cache_file": map[string]any{"enabled": true,
				"path": filepath.Join(supportDir, "cache.db")},
		},
		"inbounds": []any{map[string]any{"type": "mixed", "tag": "in",
			"listen": "127.0.0.1", "listen_port": e.settings.ProxyPort}},
		"outbounds": append([]any{
			map[string]any{"type": "selector", "tag": "proxy",
				"outbounds": append([]any{"auto"}, tags...), "default": "auto"},
			map[string]any{"type": "urltest", "tag": "auto", "outbounds": tags,
				"url": "https://www.gstatic.com/generate_204", "interval": "3m",
				"tolerance": 100},
			map[string]any{"type": "direct", "tag": "direct"},
		}, outs...),
		"route": map[string]any{"final": "proxy",
			"rules": []any{map[string]any{"ip_is_private": true, "outbound": "direct"}}},
	}
	d, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return ""
	}
	p := filepath.Join(supportDir, "singbox.json")
	if os.WriteFile(p, d, 0o600) != nil {
		return ""
	}
	return p
}

func (e *Engine) startLocked() {
	e.stopLocked()
	bin := e.singboxPath()
	if bin == "" {
		e.lastError = "sing-box не найден — установи его (" + singboxInstallHint + ")"
		return
	}
	cfg := e.writeConfigLocked()
	if cfg == "" {
		e.lastError = "нет каналов — добавь подписку"
		return
	}
	// осиротевший sing-box с нашим конфигом держит порты — убрать
	killStalePID()
	time.Sleep(300 * time.Millisecond)
	if out, err := runCmd(bin, "check", "-c", cfg); err != nil || strings.TrimSpace(out) != "" {
		e.lastError = "конфиг не прошёл проверку: " + firstN(out, 200)
		logf("%s", e.lastError)
		return
	}
	cmd := exec.Command(bin, "run", "-c", cfg, "--disable-color")
	hideWindow(cmd)
	lf, _ := os.Create(filepath.Join(supportDir, "singbox.log"))
	if lf != nil {
		cmd.Stdout = lf
		cmd.Stderr = lf
	}
	e.expectStop = false
	if err := cmd.Start(); err != nil {
		e.lastError = "не удалось запустить sing-box: " + err.Error()
		logf("%s", e.lastError)
		return
	}
	writePID(cmd.Process.Pid)
	e.proc = cmd
	e.running = true
	e.lastError = ""
	e.selected = "auto"
	logf("sing-box запущен, каналов: %d", len(e.channels))
	go func(dead *exec.Cmd) {
		err := dead.Wait()
		if lf != nil {
			lf.Close()
		}
		e.mu.Lock()
		defer e.mu.Unlock()
		// умер не актуальный процесс (его уже заменили) — игнорируем
		if e.proc != dead {
			return
		}
		e.running = false
		if !e.expectStop {
			e.lastError = fmt.Sprintf("sing-box упал (%v) — перезапускаю", err)
			logf("%s", e.lastError)
			go func() {
				time.Sleep(2 * time.Second)
				e.mu.Lock()
				defer e.mu.Unlock()
				if e.proc == dead {
					e.startLocked()
				}
			}()
		}
	}(cmd)
}

func (e *Engine) stopLocked() {
	e.expectStop = true
	if e.proc != nil && e.proc.Process != nil {
		e.proc.Process.Kill()
	}
	e.proc = nil
	e.running = false
	e.externalIP = ""
	e.now = ""
	removePID()
}

func (e *Engine) Connect() {
	e.mu.Lock()
	e.startLocked()
	e.mu.Unlock()
	go e.checkIP()
}

func (e *Engine) Disconnect() {
	e.mu.Lock()
	e.stopLocked()
	e.mu.Unlock()
}

// ------------------------------------------------------------ clash API

func (e *Engine) api(method, path string, body any, timeout time.Duration) []byte {
	e.mu.Lock()
	port, secret := e.settings.APIPort, e.settings.APISecret
	e.mu.Unlock()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, fmt.Sprintf("http://127.0.0.1:%d%s", port, path), rd)
	if err != nil {
		return nil
	}
	req.Header.Set("Authorization", "Bearer "+secret)
	cl := &http.Client{Timeout: timeout}
	resp, err := cl.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil
	}
	d, _ := io.ReadAll(resp.Body)
	if d == nil {
		d = []byte{}
	}
	return d
}

func (e *Engine) Select(tag string) {
	if e.api("PUT", "/proxies/proxy", map[string]any{"name": tag}, 10*time.Second) != nil {
		e.mu.Lock()
		e.selected = tag
		e.externalIP = ""
		e.mu.Unlock()
		go e.checkIP()
	}
}

// ------------------------------------------------------------ подписка и проверка

func (e *Engine) RefreshSubscription(probeAfter bool) {
	e.mu.Lock()
	subs := []SubEntry{}
	for _, s := range e.settings.Subscriptions {
		if s.Enabled {
			subs = append(subs, s)
		}
	}
	if len(subs) == 0 {
		e.lastError = "нет включённых списков — добавь в разделе «Списки»"
		e.mu.Unlock()
		return
	}
	e.lastSubRefresh = time.Now()
	skipRU := e.settings.SkipRU
	e.mu.Unlock()

	tags := map[string]bool{}
	var parsed []Channel
	totalLinks := 0
	for i, sub := range subs {
		e.setBusy(fmt.Sprintf("качаю список %d/%d: %s…", i+1, len(subs), sub.Name))
		links := fetchSubscription(sub.URL)
		totalLinks += len(links)
		before := len(parsed)
		for _, l := range links {
			if c := parseVless(l, tags, skipRU); c != nil {
				parsed = append(parsed, *c)
			}
		}
		logf("список '%s': %d ссылок -> +%d", sub.Name, len(links), len(parsed)-before)
	}
	e.setBusy("")
	if len(parsed) == 0 {
		e.mu.Lock()
		e.lastError = fmt.Sprintf("в списках не нашлось подходящих vless-ссылок (%d строк)", totalLinks)
		logf("%s", e.lastError)
		e.mu.Unlock()
		return
	}
	// слишком много каналов душат sing-box — равномерная выборка
	if len(parsed) > maxChannels {
		step := float64(len(parsed)) / float64(maxChannels)
		sel := make([]Channel, 0, maxChannels)
		for i := 0; i < maxChannels; i++ {
			sel = append(sel, parsed[int(float64(i)*step)])
		}
		logf("каналов %d — взял равномерно %d", len(parsed), maxChannels)
		parsed = sel
	}
	e.mu.Lock()
	e.channels = parsed
	e.delays = map[string]int{}
	e.saveChannelsLocked()
	e.lastError = ""
	logf("итого: %d ссылок -> %d каналов", totalLinks, len(parsed))
	if e.running || probeAfter {
		e.startLocked()
	}
	e.mu.Unlock()
	if probeAfter {
		e.Probe()
	}
}

func (e *Engine) setBusy(s string) {
	e.mu.Lock()
	e.busy = s
	e.mu.Unlock()
}

// ------------------------------------------------------------ управление списками

func (e *Engine) AddSub(name, u string) {
	e.mu.Lock()
	for _, s := range e.settings.Subscriptions {
		if s.URL == u {
			e.mu.Unlock()
			return
		}
	}
	e.settings.Subscriptions = append(e.settings.Subscriptions, SubEntry{Name: name, URL: u, Enabled: true})
	e.settings.save()
	e.mu.Unlock()
	go e.RefreshSubscription(true)
}

func (e *Engine) RemoveSub(u string) {
	e.mu.Lock()
	keep := e.settings.Subscriptions[:0]
	for _, s := range e.settings.Subscriptions {
		if s.URL != u {
			keep = append(keep, s)
		}
	}
	e.settings.Subscriptions = keep
	e.settings.save()
	e.mu.Unlock()
}

func (e *Engine) ToggleSub(u string) {
	e.mu.Lock()
	for i := range e.settings.Subscriptions {
		if e.settings.Subscriptions[i].URL == u {
			e.settings.Subscriptions[i].Enabled = !e.settings.Subscriptions[i].Enabled
		}
	}
	e.settings.save()
	e.mu.Unlock()
}

// ------------------------------------------------------------ проверка каналов

func (e *Engine) Probe() {
	e.mu.Lock()
	if !e.running || e.probing {
		e.mu.Unlock()
		return
	}
	e.probing = true
	e.busy = "проверяю каналы…"
	e.mu.Unlock()
	defer func() {
		e.mu.Lock()
		e.probing = false
		e.mu.Unlock()
	}()

	// sing-box мог только что перезапуститься — дождаться API
	for i := 0; i < 20; i++ {
		if e.api("GET", "/version", nil, 2*time.Second) != nil {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	// пнуть групповой тест; результаты сами лягут в history каждого прокси
	u := url.QueryEscape("https://www.gstatic.com/generate_204")
	e.api("GET", "/group/auto/delay?timeout=5000&url="+u, nil, 15*time.Second)
	// ждать, пока число живых стабилизируется (два одинаковых замера подряд)
	var d map[string]int
	last, stable := -1, 0
	for i := 0; i < 18; i++ {
		time.Sleep(5 * time.Second)
		d = e.readDelays()
		if len(d) == last && len(d) > 0 {
			stable++
			if stable >= 2 {
				break
			}
		} else {
			stable = 0
		}
		last = len(d)
	}

	e.mu.Lock()
	e.busy = ""
	e.delays = d
	alive := e.channels[:0:0]
	for _, c := range e.channels {
		if _, ok := d[c.Tag]; ok {
			alive = append(alive, c)
		}
	}
	deadCount := len(e.channels) - len(alive)
	// защита как на роутере: если умерли все — это сбой интернета, не каналов
	if deadCount > 0 && len(alive) > 0 {
		e.channels = alive
		e.saveChannelsLocked()
		logf("проверка: живых %d, удалено мёртвых %d", len(alive), deadCount)
		e.startLocked() // пересобрать конфиг без мёртвых
	} else {
		logf("проверка: живых %d из %d", len(alive), len(e.channels))
	}
	e.lastError = ""
	minCh := e.settings.MinChannels
	sinceRefresh := time.Since(e.lastSubRefresh)
	e.mu.Unlock()

	e.refreshNow()
	e.checkIP()

	e.mu.Lock()
	nowCh := e.now
	e.mu.Unlock()
	// мало живых — обновить подписку (кулдаун 10 мин);
	// но если замеров нет, а туннель работает — это сбой замера, не каналов
	if len(alive) == 0 && nowCh != "" {
		return
	}
	if len(alive) < minCh && sinceRefresh > 10*time.Minute {
		logf("AUTO-HEAL живых %d < %d — обновляю подписку", len(alive), minCh)
		e.RefreshSubscription(true)
	}
}

// пинги всех каналов из history (их меряет сам urltest)
func (e *Engine) readDelays() map[string]int {
	data := e.api("GET", "/proxies", nil, 10*time.Second)
	if data == nil {
		return map[string]int{}
	}
	var obj struct {
		Proxies map[string]struct {
			History []struct {
				Delay int `json:"delay"`
			} `json:"history"`
		} `json:"proxies"`
	}
	if json.Unmarshal(data, &obj) != nil {
		return map[string]int{}
	}
	e.mu.Lock()
	chans := make([]string, 0, len(e.channels))
	for _, c := range e.channels {
		chans = append(chans, c.Tag)
	}
	e.mu.Unlock()
	d := map[string]int{}
	for _, tag := range chans {
		p, ok := obj.Proxies[tag]
		if !ok || len(p.History) == 0 {
			continue
		}
		if ms := p.History[len(p.History)-1].Delay; ms > 0 {
			d[tag] = ms
		}
	}
	return d
}

// обновить, какой канал реально выбран
func (e *Engine) refreshNow() {
	e.mu.Lock()
	sel := e.selected
	e.mu.Unlock()
	if sel != "auto" {
		e.mu.Lock()
		e.now = sel
		e.mu.Unlock()
		return
	}
	d := e.api("GET", "/proxies/auto", nil, 5*time.Second)
	if d == nil {
		return
	}
	var o struct {
		Now string `json:"now"`
	}
	if json.Unmarshal(d, &o) == nil && o.Now != "" {
		e.mu.Lock()
		e.now = o.Now
		e.mu.Unlock()
	}
}

// ------------------------------------------------------------ watchdog

// клиент, ходящий через наш mixed-инбаунд (он же http-прокси)
func (e *Engine) proxyClient(timeout time.Duration) *http.Client {
	e.mu.Lock()
	port := e.settings.ProxyPort
	e.mu.Unlock()
	pu, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", port))
	return &http.Client{Timeout: timeout,
		Transport: &http.Transport{Proxy: http.ProxyURL(pu), DisableKeepAlives: true}}
}

func (e *Engine) HealthTick() {
	e.mu.Lock()
	running := e.running
	e.mu.Unlock()
	if !running {
		return
	}
	resp, err := e.proxyClient(8 * time.Second).Get("https://www.gstatic.com/generate_204")
	ok := false
	if err == nil {
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		ok = resp.StatusCode == 204
	}
	if ok {
		e.mu.Lock()
		e.failCount = 0
		needIP := e.externalIP == ""
		e.mu.Unlock()
		e.refreshNow()
		if needIP {
			e.checkIP()
		}
		return
	}
	e.mu.Lock()
	e.failCount++
	fc := e.failCount
	sinceRefresh := time.Since(e.lastSubRefresh)
	e.mu.Unlock()
	logf("watchdog: туннель не отвечает (%d)", fc)
	if fc == 2 {
		// пнуть urltest — пусть перевыберет живой канал
		u := url.QueryEscape("https://www.gstatic.com/generate_204")
		e.api("GET", "/group/auto/delay?timeout=5000&url="+u, nil, 60*time.Second)
	} else if fc >= 4 && sinceRefresh > 10*time.Minute {
		e.mu.Lock()
		e.failCount = 0
		e.mu.Unlock()
		logf("AUTO-HEAL связь пропала — обновляю подписку")
		go e.RefreshSubscription(true)
	}
}

func (e *Engine) checkIP() {
	e.mu.Lock()
	running := e.running
	e.mu.Unlock()
	if !running {
		return
	}
	resp, err := e.proxyClient(8 * time.Second).Get("https://api.ipify.org")
	if err == nil {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 64))
		resp.Body.Close()
		ip := strings.TrimSpace(string(b))
		if ip != "" && len(ip) < 46 && resp.StatusCode == 200 {
			e.mu.Lock()
			e.externalIP = ip
			e.mu.Unlock()
		}
	}
	e.refreshNow()
}

// ------------------------------------------------------------ pid-файл против сирот

func pidPath() string { return filepath.Join(supportDir, "singbox.pid") }

func writePID(pid int) { os.WriteFile(pidPath(), []byte(strconv.Itoa(pid)), 0o644) }
func removePID()       { os.Remove(pidPath()) }

func killStalePID() {
	d, err := os.ReadFile(pidPath())
	if err != nil {
		return
	}
	if pid, err := strconv.Atoi(strings.TrimSpace(string(d))); err == nil && pid > 0 {
		if p, err := os.FindProcess(pid); err == nil {
			p.Kill()
		}
	}
	os.Remove(pidPath())
}

func runCmd(bin string, args ...string) (string, error) {
	cmd := exec.Command(bin, args...)
	hideWindow(cmd)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func firstN(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) > n {
		return s[:n]
	}
	return s
}
