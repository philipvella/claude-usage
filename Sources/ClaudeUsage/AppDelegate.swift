import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let refreshInterval: TimeInterval = 5 * 60
    private static let displayKeyDefaults = "menuBarWindowKey"

    private let service = UsageService()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var loginController: LoginWindowController?

    private var snapshot: UsageSnapshot?
    private var lastError: Error?
    private var isRefreshing = false

    private var displayKey: String {
        get { UserDefaults.standard.string(forKey: Self.displayKeyDefaults) ?? "five_hour" }
        set { UserDefaults.standard.set(newValue, forKey: Self.displayKeyDefaults) }
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        updateStatusButton()

        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 15

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        Task {
            if await service.isSignedIn() {
                refresh()
            } else {
                showLogin()
            }
        }
    }

    // MARK: Refresh

    @objc private func refreshNow() { refresh() }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        updateStatusButton()
        Task {
            defer {
                isRefreshing = false
                updateStatusButton()
            }
            do {
                snapshot = try await service.fetch()
                lastError = nil
            } catch {
                lastError = error
                if case UsageError.notSignedIn = error { snapshot = nil }
                if case UsageError.unauthorized = error { snapshot = nil }
            }
        }
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let window = snapshot?.window(displayKey) ?? snapshot?.windows.first
        if let window {
            button.image = PieIcon.image(percent: window.utilization)
            button.title = " \(Int(window.utilization.rounded()))%"
            button.toolTip = "Claude – \(window.label): \(Int(window.utilization.rounded()))%"
        } else {
            button.image = PieIcon.image(percent: nil)
            button.title = lastError != nil ? " !" : ""
            button.toolTip = lastError?.localizedDescription ?? "Claude usage"
        }
        button.appearsDisabled = isRefreshing && snapshot == nil
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let snapshot, !snapshot.windows.isEmpty {
            for w in snapshot.windows {
                let pct = Int(w.utilization.rounded())
                let item = NSMenuItem(title: "\(w.label): \(pct)%", action: nil, keyEquivalent: "")
                item.image = PieIcon.image(percent: w.utilization, size: 14)
                if let reset = w.resetsAt {
                    let text = "Resets \(Self.relative(reset))"
                    if #available(macOS 14.4, *) {
                        item.subtitle = text
                    } else {
                        item.title += "  ·  \(text)"
                    }
                }
                item.isEnabled = true
                item.target = self
                item.action = #selector(noop)
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let updated = NSMenuItem(title: "Updated \(Self.relative(snapshot.fetchedAt))", action: nil, keyEquivalent: "")
            updated.isEnabled = false
            menu.addItem(updated)
        } else if lastError == nil {
            let item = NSMenuItem(title: isRefreshing ? "Loading…" : "No data yet", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if let lastError {
            let item = NSMenuItem(title: "⚠︎ \(lastError.localizedDescription)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: isRefreshing ? "Refreshing…" : "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Open Usage on claude.ai", action: #selector(openUsagePage), keyEquivalent: "").target = self

        // Which limit drives the menu bar pie.
        if let snapshot, snapshot.windows.count > 1 {
            let sub = NSMenu()
            for w in snapshot.windows {
                let item = NSMenuItem(title: w.label, action: #selector(selectDisplayWindow(_:)), keyEquivalent: "")
                item.representedObject = w.key
                item.state = (w.key == displayKey) ? .on : .off
                item.target = self
                sub.addItem(item)
            }
            let parent = NSMenuItem(title: "Show in Menu Bar", action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Sign In…", action: #selector(signInAgain), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Paste Session Key…", action: #selector(pasteSessionKey), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Sign Out", action: #selector(signOut), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Claude Usage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func noop() {}

    @objc private func selectDisplayWindow(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        displayKey = key
        updateStatusButton()
    }

    @objc private func openUsagePage() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    // MARK: Auth

    private func showLogin() {
        if let loginController {
            loginController.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = LoginWindowController(dataStore: service.dataStore)
        controller.onSuccess = { [weak self] in
            self?.lastError = nil
            self?.refresh()
        }
        controller.onClose = { [weak self] in
            self?.loginController = nil
        }
        loginController = controller
        controller.start()
    }

    @objc private func signInAgain() { showLogin() }

    @objc private func signOut() {
        Task {
            await service.signOut()
            snapshot = nil
            lastError = UsageError.notSignedIn
            updateStatusButton()
        }
    }

    @objc private func pasteSessionKey() {
        let alert = NSAlert()
        alert.messageText = "Paste Claude session key"
        alert.informativeText = "Use this if web sign-in doesn't work (e.g. Google SSO). In a browser signed in to claude.ai, open Developer Tools → Storage/Application → Cookies → https://claude.ai and copy the value of “sessionKey”."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-sid01-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Task {
            await service.setManualSessionKey(key)
            lastError = nil
            refresh()
        }
    }

    // MARK: Helpers

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}
