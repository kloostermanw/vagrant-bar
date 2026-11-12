import AppKit
import VagrantCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let client = VagrantClient()
    private let updates = UpdateService(reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) })
    private var updateTimer: Timer?
    private let queue = DispatchQueue(label: "vagrant-bar.commands")

    private var statusItem: NSStatusItem!
    private var machines: [VagrantMachine] = []
    private var lastError: String?
    /// Machines with an action started from this app.
    private var busyMachines: Set<String> = []
    /// Machines a vagrant command outside this app is working on (terminal, ...).
    private var externalBusyMachines: Set<String> = []
    private var refreshing = false
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        refresh()
        // Scheduled timers fire on the main run loop.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        updates.onStateChange = { [weak self] state in
            // Present after the state change has finished propagating, so an alert's
            // modal loop never runs inside UpdateService's own call stack.
            DispatchQueue.main.async { self?.updateStateChanged(state) }
        }
        checkForUpdatesInBackground()
        // The throttle in UpdateService decides when a check actually runs (every 2 hours);
        // ticking more often keeps that interval from drifting to twice the throttle.
        updateTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForUpdatesInBackground() }
        }
    }

    // MARK: - Refresh

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        queue.async { [client] in
            let result = Result { try client.globalStatus() }
            let processes = VagrantProcesses.running()
            DispatchQueue.main.async {
                self.refreshing = false
                switch result {
                case .success(let machines):
                    self.machines = machines
                    self.externalBusyMachines = VagrantProcesses.busyMachineIDs(machines, processes: processes)
                    self.lastError = nil
                case .failure(let error):
                    self.lastError = error.localizedDescription
                }
                self.updateIcon()
                if let menu = self.statusItem.menu { self.buildMenu(menu) }
            }
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let anyRunning = machines.contains(where: \.isRunning)
        let title = busyMachines.isEmpty && externalBusyMachines.isEmpty ? "V" : "V…"
        let font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize(for: .regular) + 1)
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if anyRunning {
            attributes[.foregroundColor] = NSColor.systemGreen
        }
        button.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        button.toolTip = anyRunning
            ? "\(machines.filter(\.isRunning).count) Vagrant machine(s) running"
            : "No Vagrant machines running"
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        buildMenu(menu)
        refresh()
    }

    private func buildMenu(_ menu: NSMenu) {
        apply(menuItems(), to: menu)
    }

    /// Updates the menu to show `items`. The menu is rebuilt while it is open (a refresh
    /// finishing), and macOS mis-sizes an open menu whose items are all removed and
    /// re-added, leaving an empty row under Quit. So when the layout is unchanged,
    /// update the existing items in place and only rebuild when rows come or go.
    private func apply(_ items: [NSMenuItem], to menu: NSMenu) {
        let sameLayout = menu.items.count == items.count
            && zip(menu.items, items).allSatisfy { $0.isSeparatorItem == $1.isSeparatorItem }
        guard sameLayout else {
            menu.removeAllItems()
            items.forEach(menu.addItem)
            return
        }
        for (existing, item) in zip(menu.items, items) where !item.isSeparatorItem {
            existing.title = item.title
            existing.attributedTitle = item.attributedTitle
            existing.action = item.action
            existing.target = item.target
            existing.representedObject = item.representedObject
            existing.keyEquivalent = item.keyEquivalent
            existing.isEnabled = item.isEnabled
            existing.toolTip = item.toolTip
            // A submenu can only belong to one item: detach it from the throwaway item first.
            let submenu = item.submenu
            item.submenu = nil
            existing.submenu = submenu
        }
    }

    private func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        if let lastError {
            let item = NSMenuItem(title: lastError, action: nil, keyEquivalent: "")
            item.isEnabled = false
            items.append(item)
            items.append(.separator())
        }

        if machines.isEmpty && lastError == nil {
            let item = NSMenuItem(title: "No Vagrant machines", action: nil, keyEquivalent: "")
            item.isEnabled = false
            items.append(item)
        }

        for machine in machines {
            items.append(machineItem(machine))
        }

        items.append(.separator())
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        items.append(refreshItem)
        items.append(.separator())
        items += updateMenuItems()
        items.append(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return items
    }

    private func machineItem(_ machine: VagrantMachine) -> NSMenuItem {
        let item = NSMenuItem(title: machine.name, action: nil, keyEquivalent: "")
        let busy = isBusy(machine)

        let dot = machine.isRunning ? "●" : "○"
        let title = NSMutableAttributedString(
            string: dot + "  ",
            attributes: machine.isRunning ? [.foregroundColor: NSColor.systemGreen] : [:]
        )
        title.append(NSAttributedString(string: machine.name + (busy ? "  …" : "")))
        item.attributedTitle = title
        item.toolTip = "\(machine.home)\n\(machine.provider) — \(machine.state) (\(machine.id))"

        let sub = NSMenu()
        sub.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.representedObject = machine.id
            i.isEnabled = enabled && !busy
            sub.addItem(i)
        }
        add("Up", #selector(upClicked(_:)), enabled: !machine.isRunning)
        add("Halt", #selector(haltClicked(_:)), enabled: machine.isRunning)
        add("Reload", #selector(reloadClicked(_:)), enabled: machine.isRunning)
        sub.addItem(.separator())
        add("SSH", #selector(sshClicked(_:)), enabled: machine.isRunning)
        add("Open Folder", #selector(openFolderClicked(_:)), enabled: !machine.home.isEmpty)
        item.submenu = sub
        return item
    }

    // MARK: - Actions

    @objc private func refreshClicked() { refresh() }
    @objc private func upClicked(_ sender: NSMenuItem) { runAction("up", sender) }
    @objc private func haltClicked(_ sender: NSMenuItem) { runAction("halt", sender) }
    @objc private func reloadClicked(_ sender: NSMenuItem) { runAction("reload", sender) }

    @objc private func openFolderClicked(_ sender: NSMenuItem) {
        guard let machine = machine(for: sender) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: machine.home))
    }

    @objc private func sshClicked(_ sender: NSMenuItem) {
        guard let machine = machine(for: sender) else { return }
        let shellQuoted = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = "cd \(shellQuoted(machine.home)) && \(shellQuoted(client.binary)) ssh \(machine.id)"
        let appleScriptString = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(appleScriptString)"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
        } catch {
            showError(title: "Could not open Terminal", message: error.localizedDescription)
        }
    }

    private func isBusy(_ machine: VagrantMachine) -> Bool {
        busyMachines.contains(machine.id) || externalBusyMachines.contains(machine.id)
    }

    private func machine(for sender: NSMenuItem) -> VagrantMachine? {
        guard let id = sender.representedObject as? String else { return nil }
        return machines.first { $0.id == id }
    }

    private func runAction(_ command: String, _ sender: NSMenuItem) {
        guard let machine = machine(for: sender) else { return }
        busyMachines.insert(machine.id)
        updateIcon()

        // Actions run off the refresh queue so long `up`s don't block status updates.
        DispatchQueue.global(qos: .userInitiated).async { [client] in
            let result = Result { try client.run([command, machine.id], in: machine.home) }
            DispatchQueue.main.async {
                self.busyMachines.remove(machine.id)
                switch result {
                case .success(let r) where r.status != 0:
                    let output = r.stderr.isEmpty ? r.stdout : r.stderr
                    if VagrantClient.isMachineLockedError(output) {
                        self.showError(title: "\(machine.name) is busy",
                                       message: "Another Vagrant command is still working on this machine. Try again when it finishes.")
                        break
                    }
                    self.showError(title: "vagrant \(command) failed for \(machine.name)",
                                   message: VagrantClient.tail(output))
                case .failure(let error):
                    self.showError(title: "vagrant \(command) failed for \(machine.name)",
                                   message: error.localizedDescription)
                default:
                    break
                }
                self.updateIcon()
                self.refresh()
            }
        }
    }

    private func showError(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - About & updates

    private func updateMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        // A nil action leaves the item disabled (the menu auto-enables items).
        func item(_ title: String, _ action: Selector?) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            items.append(i)
        }

        switch updates.state {
        case .available(let release):
            item("Update available: \(release.version)…", #selector(showUpdateClicked))
        case .downloading:
            item("Downloading update…", nil)
        default:
            break
        }
        item("About VagrantBar", #selector(aboutClicked))
        if updates.state == .checking {
            item("Checking for Updates…", nil)
        } else {
            item("Check for Updates…", #selector(checkForUpdatesClicked))
        }
        return items
    }

    @objc private func aboutClicked() {
        // Accessory apps aren't frontmost; activate so the panel isn't hidden behind other windows.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func checkForUpdatesClicked() {
        Task { await updates.checkForUpdates(userInitiated: true) }
    }

    @objc private func showUpdateClicked() {
        if case .available(let release) = updates.state { showUpdateAvailable(release) }
    }

    private func checkForUpdatesInBackground() {
        Task { await updates.checkForUpdates(userInitiated: false) }
    }

    private func updateStateChanged(_ state: UpdateService.State) {
        if let menu = statusItem.menu { buildMenu(menu) }
        // Ignore stale notifications: the state may have moved on before this ran.
        guard state == updates.state else { return }

        switch state {
        case .available(let release):
            showUpdateAvailable(release)
        case .upToDate:
            showInfo(title: "You're up to date",
                     message: "VagrantBar \(updates.currentVersion) is the latest version.")
            updates.dismiss()
        case .failed(let message):
            showError(title: "Update failed", message: message)
            updates.dismiss()
        case .downloaded:
            showInfo(title: "Download complete",
                     message: "The installer was revealed in Finder. Open it, then drag VagrantBar to your Applications folder.")
            updates.dismiss()
        case .idle, .checking, .downloading:
            break
        }
    }

    private func showUpdateAvailable(_ release: GitHubRelease) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Update available"
        alert.informativeText = "VagrantBar \(release.version) is available. You have \(updates.currentVersion)."
        if !release.body.isEmpty {
            alert.accessoryView = releaseNotesView(release.body)
        }
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Skip This Version")
        alert.addButton(withTitle: "Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { await updates.download(release) }
        case .alertSecondButtonReturn:
            updates.skip(release)
        default:
            // Later: keep the update around so the menu can reopen this alert.
            break
        }
    }

    private func releaseNotesView(_ notes: String) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 360, height: 160)
        scroll.borderType = .bezelBorder
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.string = notes
            text.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        return scroll
    }

    private func showInfo(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
