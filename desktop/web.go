package main

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"
)

//go:embed ui.html
var uiHTML []byte

type chanState struct {
	Tag   string `json:"tag"`
	Delay int    `json:"delay"` // 0 = ещё не мерили / мёртв
}

type webState struct {
	Running     bool        `json:"running"`
	Busy        string      `json:"busy"`
	Error       string      `json:"error"`
	IP          string      `json:"ip"`
	Selected    string      `json:"selected"`
	Now         string      `json:"now"`
	FailCount   int         `json:"failCount"`
	Channels    []chanState `json:"channels"`
	AliveCount  int         `json:"aliveCount"`
	Subs        []SubEntry  `json:"subs"`
	Presets     []Preset    `json:"presets"`
	SysProxy    bool        `json:"sysProxy"`
	Autostart   bool        `json:"autostart"`
	SkipRU      bool        `json:"skipRU"`
	MinChannels int         `json:"minChannels"`
	ProxyPort   int         `json:"proxyPort"`
	Platform    string      `json:"platform"`
}

func (e *Engine) snapshot() webState {
	e.mu.Lock()
	defer e.mu.Unlock()
	st := webState{
		Running: e.running, Busy: e.busy, Error: e.lastError, IP: e.externalIP,
		Selected: e.selected, Now: e.now, FailCount: e.failCount,
		Subs: append([]SubEntry{}, e.settings.Subscriptions...), Presets: topPresets,
		SysProxy: e.settings.SystemProxyOn, Autostart: isAutostartOn(),
		SkipRU: e.settings.SkipRU, MinChannels: e.settings.MinChannels,
		ProxyPort: e.settings.ProxyPort, Platform: platformName,
	}
	for _, c := range e.channels {
		d := e.delays[c.Tag]
		st.Channels = append(st.Channels, chanState{Tag: c.Tag, Delay: d})
		if d > 0 {
			st.AliveCount++
		}
	}
	sort.SliceStable(st.Channels, func(i, j int) bool {
		a, b := st.Channels[i].Delay, st.Channels[j].Delay
		if (a > 0) != (b > 0) {
			return a > 0
		}
		return a < b
	})
	return st
}

func serveWeb(e *Engine, port int, quitCh chan struct{}) (net.Listener, error) {
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		return nil, err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(uiHTML)
	})
	jsonOK := func(w http.ResponseWriter, v any) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(v)
	}
	readBody := func(r *http.Request) map[string]string {
		var m map[string]string
		json.NewDecoder(r.Body).Decode(&m)
		if m == nil {
			m = map[string]string{}
		}
		return m
	}
	mux.HandleFunc("/api/state", func(w http.ResponseWriter, r *http.Request) {
		jsonOK(w, e.snapshot())
	})
	mux.HandleFunc("/api/log", func(w http.ResponseWriter, r *http.Request) {
		jsonOK(w, map[string]any{"lines": logRing.get()})
	})
	mux.HandleFunc("/api/connect", func(w http.ResponseWriter, r *http.Request) {
		go func() { e.Connect(); go e.Probe() }()
		jsonOK(w, map[string]bool{"ok": true})
	})
	mux.HandleFunc("/api/disconnect", func(w http.ResponseWriter, r *http.Request) {
		go e.Disconnect()
		jsonOK(w, map[string]bool{"ok": true})
	})
	mux.HandleFunc("/api/probe", func(w http.ResponseWriter, r *http.Request) {
		go e.Probe()
		jsonOK(w, map[string]bool{"ok": true})
	})
	mux.HandleFunc("/api/refresh", func(w http.ResponseWriter, r *http.Request) {
		go e.RefreshSubscription(true)
		jsonOK(w, map[string]bool{"ok": true})
	})
	mux.HandleFunc("/api/select", func(w http.ResponseWriter, r *http.Request) {
		tag := readBody(r)["tag"]
		if tag == "" {
			tag = "auto"
		}
		go e.Select(tag)
		jsonOK(w, map[string]bool{"ok": true})
	})
	mux.HandleFunc("/api/subs/add", func(w http.ResponseWriter, r *http.Request) {
		m := readBody(r)
		u, name := strings.TrimSpace(m["url"]), strings.TrimSpace(m["name"])
		if !strings.HasPrefix(u, "http://") && !strings.HasPrefix(u, "https://") {
			jsonOK(w, map[string]any{"ok": false, "error": "нужен http(s)-URL"})
			return
		}
		if name == "" {
			for _, p := range topPresets {
				if p.URL == u {
					name = p.Name
				}
			}
		}
		if name == "" {
			name = "Список " + time.Now().Format("02.01 15:04")
		}
		e.AddSub(name, u)
		jsonOK(w, map[string]bool{"ok": true})
	})
	mux.HandleFunc("/api/subs/remove", func(w http.ResponseWriter, r *http.Request) {
		e.RemoveSub(readBody(r)["url"])
		jsonOK(w, map[string]bool{"ok": true})
	})
	mux.HandleFunc("/api/subs/toggle", func(w http.ResponseWriter, r *http.Request) {
		e.ToggleSub(readBody(r)["url"])
		jsonOK(w, map[string]bool{"ok": true})
	})
	mux.HandleFunc("/api/sysproxy", func(w http.ResponseWriter, r *http.Request) {
		on := readBody(r)["on"] == "1"
		e.mu.Lock()
		port := e.settings.ProxyPort
		e.mu.Unlock()
		if err := setSystemProxy(on, port); err != nil {
			jsonOK(w, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		e.mu.Lock()
		e.settings.SystemProxyOn = on
		e.settings.save()
		e.mu.Unlock()
		jsonOK(w, map[string]bool{"ok": true})
	})
	mux.HandleFunc("/api/autostart", func(w http.ResponseWriter, r *http.Request) {
		on := readBody(r)["on"] == "1"
		if err := setAutostart(on); err != nil {
			jsonOK(w, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		jsonOK(w, map[string]bool{"ok": true})
	})
	mux.HandleFunc("/api/quit", func(w http.ResponseWriter, r *http.Request) {
		jsonOK(w, map[string]bool{"ok": true})
		go func() {
			time.Sleep(200 * time.Millisecond)
			close(quitCh)
		}()
	})
	srv := &http.Server{Handler: mux}
	go srv.Serve(ln)
	_ = os.Getpid
	return ln, nil
}
