import AppKit
import VagrantCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let client = VagrantClient()
    private let queue = DispatchQueue(label: "vagrant-bar.commands")

    private var statusItem: NSStatusItem!
    private var machines: [VagrantMachine] = []
    private var lastError: String?
    private var busyMachines: Set<String> = []
    private var refreshing = false
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Refresh

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        queue.async { [client] in
            let result = Result { try client.globalStatus() }
            DispatchQueue.main.async {
                self.refreshing = false
                switch result {
                case .success(let machines):
                    self.machines = machines
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
        let title = busyMachines.isEmpty ? "V" : "V…"
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
        menu.removeAllItems()

        if let lastError {
            let item = NSMenuItem(title: lastError, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if machines.isEmpty && lastError == nil {
            let item = NSMenuItem(title: "No Vagrant machines", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        for machine in machines {
            menu.addItem(machineItem(machine))
        }

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func machineItem(_ machine: VagrantMachine) -> NSMenuItem {
        let item = NSMenuItem(title: machine.name, action: nil, keyEquivalent: "")
        let busy = busyMachines.contains(machine.id)

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
}
