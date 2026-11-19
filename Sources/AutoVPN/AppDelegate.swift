import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var timer: Timer?
    var debugWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        updateIcon(EngineSnapshot())

        popover.contentViewController = NSHostingController(rootView: RootView())
        popover.contentSize = NSSize(width: 380, height: 660)
        popover.behavior = .transient

        Engine.shared.onChange = { [weak self] snap in
            UIModel.shared.apply(snap)
            self?.updateIcon(snap)
        }
        Engine.shared.poke()

        // «наш принцип»: есть каналы — подключаемся, есть списки — качаем и подключаемся
        let e = Engine.shared
        if !e.channels.isEmpty {
            e.connect()
            e.q.asyncAfter(deadline: .now() + 2) { e.probe() }
        } else if e.settings.subscriptions.contains(where: { $0.enabled }) {
            e.refreshSubscription()
        }
        if e.settings.systemProxyOn {
            DispatchQueue.global().async { _ = SystemProxy.set(on: true) }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Engine.shared.healthTick()
        }

        // отладочное окно для скриншота дизайна
        if ProcessInfo.processInfo.environment["AUTOVPN_WINDOW"] != nil {
            let w = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 380, height: 660),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "AutoVPN"
            w.contentViewController = NSHostingController(rootView: RootView())
            w.setFrameTopLeftPoint(NSPoint(x: 120, y: (NSScreen.main?.frame.height ?? 900) - 60))
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            debugWindow = w
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Engine.shared.settings.systemProxyOn { _ = SystemProxy.set(on: false) }
        Engine.shared.disconnect()
        Thread.sleep(forTimeInterval: 0.3)
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func updateIcon(_ s: EngineSnapshot) {
        let name = s.running
            ? (s.failCount >= 2 ? "bolt.horizontal.circle" : "bolt.horizontal.circle.fill")
            : "bolt.horizontal.circle"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "AutoVPN")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.appearsDisabled = !s.running
    }
}
