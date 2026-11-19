package main

import (
	"flag"
	"fmt"
	"net/http"
	"time"
)

func main() {
	noBrowser := flag.Bool("no-browser", false, "не открывать панель в браузере при старте")
	flag.Parse()

	e := newEngine()
	webURL := fmt.Sprintf("http://127.0.0.1:%d/", e.settings.WebPort)

	quitCh := make(chan struct{})
	ln, err := serveWeb(e, e.settings.WebPort, quitCh)
	if err != nil {
		// уже запущен — просто показать панель работающего экземпляра
		if r, err2 := http.Get(webURL + "api/state"); err2 == nil {
			r.Body.Close()
			openBrowser(webURL)
			return
		}
		logf("порт веб-панели занят: %v", err)
		return
	}
	defer ln.Close()
	logf("панель: %s", webURL)

	// «наш принцип»: есть каналы — подключаемся, есть списки — качаем и подключаемся
	go func() {
		e.mu.Lock()
		hasChannels := len(e.channels) > 0
		hasSubs := false
		for _, s := range e.settings.Subscriptions {
			if s.Enabled {
				hasSubs = true
			}
		}
		sysProxy := e.settings.SystemProxyOn
		proxyPort := e.settings.ProxyPort
		e.mu.Unlock()
		if hasChannels {
			e.Connect()
			time.Sleep(2 * time.Second)
			go e.Probe()
		} else if hasSubs {
			e.RefreshSubscription(true)
		}
		if sysProxy {
			setSystemProxy(true, proxyPort)
		}
	}()

	go func() {
		t := time.NewTicker(30 * time.Second)
		for range t.C {
			e.HealthTick()
		}
	}()

	if !*noBrowser {
		openBrowser(webURL)
	}

	<-quitCh
	e.mu.Lock()
	sysProxy := e.settings.SystemProxyOn
	proxyPort := e.settings.ProxyPort
	e.mu.Unlock()
	if sysProxy {
		setSystemProxy(false, proxyPort)
	}
	e.Disconnect()
	logf("выход")
}
