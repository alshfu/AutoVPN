# ⚡ AutoVPN

**Самонаводящийся VPN-клиент для macOS, Windows и Linux.** Добавляешь подписку с VLESS-ссылками — он сам находит живые серверы, подключается через самый быстрый и сам себя чинит. Ноль настроек, ноль ручного перебора каналов.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![Windows](https://img.shields.io/badge/Windows-10%2B-0078D4)
![Linux](https://img.shields.io/badge/Linux-x64%20%7C%20arm64-FCC624?logo=linux&logoColor=black)
![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)
![Go](https://img.shields.io/badge/Go-1.22%2B-00ADD8?logo=go&logoColor=white)
![sing-box](https://img.shields.io/badge/engine-sing--box-blue)
![License](https://img.shields.io/badge/license-MIT-green)

<p align="center">
<img src="docs/screenshot.png" width="340" alt="AutoVPN для macOS">
<img src="docs/screenshot-desktop.png" width="340" alt="AutoVPN для Windows/Linux">
</p>

> *Fastest channel wins.* Пока обычные клиенты ждут, что ты сам потыкаешь по сотне серверов, AutoVPN проверяет их все и держится за лучший.

## Зачем

Публичные подписки — это тысячи ссылок, из которых живы единицы, и они умирают каждый день. Перебирать их руками в обычном клиенте — боль. AutoVPN превращает это в конвейер:

```
подписки ──► фильтр (tls/reality, мусор мимо) ──► выборка до 400
                                                       │
     самолечение ◄── удаление мёртвых ◄── замер всех ◄─┘
          │
          └─► всегда подключён через самый быстрый живой канал
```

## Два клиента — один принцип

| | macOS (`macos/`) | Windows / Linux (`desktop/`) |
|---|---|---|
| Что это | Нативное menu-bar приложение | Один бинарник без зависимостей |
| UI | SwiftUI-попап у иконки ⚡ | Неоновая веб-панель на `127.0.0.1:2082` |
| Язык | Swift | Go (чистый stdlib) |
| Системный прокси | кнопка (networksetup) | кнопка (реестр WinINET / gsettings) |
| Автозапуск | SMAppService | реестр Run / autostart .desktop |

Движок одинаковый: sing-box с urltest-группой, проверка живости по history каждого канала, отсев мёртвых с предохранителем, автообновление списков при деградации, watchdog каждые 30 секунд.

## Возможности

- 🚀 **Авто-отбор** — urltest-группа sing-box сама выбирает быстрейший сервер и мгновенно переключается при падении
- 📋 **Несколько подписок** — добавляй свои URL, включай/выключай, плюс 5 вшитых популярных списков
- 💀 **Чистка мёртвых** — каналы без отклика удаляются (с предохранителем: если умерли все разом — это сбой сети, не трогаем)
- 🏥 **Самолечение** — живых каналов меньше 4 или туннель упал → подписки перекачиваются автоматически
- 🖥 **Системный прокси** — одна кнопка, и весь трафик идёт через туннель
- 🧬 **Нативно** — Swift и Go, без Electron и без Python
- 🌚 **Неоновый UI** — статус-орб, пинг-бары, клик по каналу = закрепить

## Установка

Везде нужен [sing-box](https://sing-box.sagernet.org/):

- macOS: `brew install sing-box`
- Windows: `winget install SagerNet.sing-box` (или положи `sing-box.exe` рядом с `autovpn.exe`)
- Linux: [пакеты sing-box](https://sing-box.sagernet.org/installation/package-managers/)

### macOS (menu-bar приложение)

Скачай `AutoVPN.app.zip` из [Releases](../../releases) (подпись ad-hoc — при первом запуске: правый клик → «Открыть»), или собери сам:

```bash
git clone https://github.com/alshfu/AutoVPN.git
cd AutoVPN/macos
./scripts/build-app.sh
cp -R dist/AutoVPN.app ~/Applications/
open ~/Applications/AutoVPN.app
```

### Windows

Скачай `autovpn-windows-amd64.exe` из [Releases](../../releases) и запусти — откроется панель в браузере. Кнопка «АВТОЗАПУСК» прописывает его в автостарт. SmartScreen при первом запуске: «Подробнее» → «Выполнить в любом случае».

### Linux

```bash
wget https://github.com/alshfu/AutoVPN/releases/latest/download/autovpn-linux-amd64
chmod +x autovpn-linux-amd64
./autovpn-linux-amd64        # панель: http://127.0.0.1:2082
```

Есть и `autovpn-linux-arm64` (Raspberry Pi, ARM-серверы). Сборка из исходников: `cd desktop && go build`.

## Как пользоваться

1. Открой панель (macOS: клик по ⚡ в строке меню; Windows/Linux: http://127.0.0.1:2082)
2. В «СПИСКИ» вставь URL подписки (сырые `vless://`-ссылки или base64) — или раскрой «ТОП-5 ПОПУЛЯРНЫХ» и добавь готовый
3. Всё. Клиент скачает список, проверит каналы и подключится через самый быстрый
4. SOCKS/HTTP-прокси доступен на `127.0.0.1:2080`; кнопка «СИСТ. ПРОКСИ» заворачивает весь трафик системы

Прокси вручную: `curl --proxy socks5h://127.0.0.1:2080 https://api.ipify.org`

## Под капотом

- Принимаются только `vless://` с `security=tls|reality` — остальное отбрасывается, включая RU-выходы (опция)
- Из больших списков берётся равномерная выборка до 400 каналов — больше sing-box не нужно
- Живость меряется не групповым delay-эндпоинтом (он в sing-box 1.14 отвечает `{}` мгновенно), а историей задержек каждого канала из `GET /proxies`
- Мусорные uTLS-отпечатки (`fp=unsafe`) фильтруются по белому списку; reality без отпечатка получает `chrome`; flow нормализуется до `xtls-rprx-vision`
- Конфиг проверяется `sing-box check` до запуска; watchdog каждые 30 с проверяет туннель сквозным запросом
- Файлы: macOS `~/Library/Application Support/AutoVPN/`, Windows `%AppData%\AutoVPN\`, Linux `~/.config/AutoVPN/`

## English

**Self-healing VPN client for macOS, Windows and Linux.** Feed it VLESS subscription URLs — it filters junk, probes every server, connects through the fastest one and keeps healing itself: dead channels get pruned, and when fewer than 4 remain alive it re-fetches your subscriptions automatically. Two native clients, one engine: a Swift menu-bar app for macOS and a single dependency-free Go binary with a neon web panel for Windows/Linux, both powered by [sing-box](https://sing-box.sagernet.org/). System-wide proxy toggle, autostart, built-in top-5 public subscription presets. MIT.

## Лицензия

[MIT](LICENSE). Используйте VPN в соответствии с законами вашей страны.
