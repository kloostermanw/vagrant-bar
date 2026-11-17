import AppKit
import SwiftUI
import VagrantCore

/// Shared state between the Settings window and the menu. Every edit is saved immediately.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var commands: [CustomCommand] {
        didSet {
            store.save(commands)
            onChange?()
        }
    }
    @Published var machines: [VagrantMachine] = []
    var onChange: (() -> Void)?
    private let store: CustomCommandStore

    init(store: CustomCommandStore = CustomCommandStore()) {
        self.store = store
        self.commands = store.load()
    }

    /// Machines to offer in the target picker: the ones Vagrant knows about now, plus any
    /// folder a command still targets, so a selection isn't lost while a machine is gone.
    func pickerMachines(for command: CustomCommand) -> [(name: String, home: String)] {
        var result = machines.filter { !$0.home.isEmpty }.map { (name: $0.name, home: $0.home) }
        if case .machines(let homes) = command.targets {
            for home in homes where !result.contains(where: { $0.home == home }) {
                result.append((name: URL(fileURLWithPath: home).lastPathComponent + " (not found)", home: home))
            }
        }
        return result
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init(model: SettingsModel) {
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        // Only enforce the minimum size; otherwise SwiftUI pins the window to its ideal size.
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "VagrantBar Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 480))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SettingsWindow")
        if window.frame.origin == .zero { window.center() }
        self.init(window: window)
    }

    func show() {
        // Accessory apps aren't frontmost; activate so the window isn't hidden behind other apps.
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 620, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .onAppear {
            if selection == nil { selection = model.commands.first?.id }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Commands") {
                    ForEach(model.commands) { command in
                        Label(command.name.isEmpty ? "Untitled" : command.name, systemImage: "terminal")
                            .foregroundColor(command.isComplete ? .primary : .secondary)
                            .tag(command.id)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 0) {
                Button(action: add) {
                    Image(systemName: "plus").frame(width: 28, height: 24)
                }
                .help("Add a command")
                Divider().frame(height: 16)
                Button(action: remove) {
                    Image(systemName: "minus").frame(width: 28, height: 24)
                }
                .help("Remove the selected command")
                .disabled(selection == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let index = model.commands.firstIndex(where: { $0.id == selection }) {
            CommandEditor(command: $model.commands[index],
                          machines: model.pickerMachines(for: model.commands[index]))
                .id(model.commands[index].id)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(.secondary)
                Text(model.commands.isEmpty ? "No Commands" : "No Command Selected")
                    .font(.title3.weight(.semibold))
                Text("Custom commands run inside your Vagrant machines and appear in each machine's menu.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: 300)
                if model.commands.isEmpty {
                    Button("Add Command", action: add)
                        .controlSize(.large)
                        .padding(.top, 4)
                }
            }
            .padding()
        }
    }

    private func add() {
        let command = CustomCommand(name: "New Command", command: "")
        model.commands.append(command)
        selection = command.id
    }

    private func remove() {
        guard let selection, let index = model.commands.firstIndex(where: { $0.id == selection }) else { return }
        model.commands.remove(at: index)
        let next = min(index, model.commands.count - 1)
        self.selection = next >= 0 ? model.commands[next].id : nil
    }
}

private struct CommandEditor: View {
    @Binding var command: CustomCommand
    let machines: [(name: String, home: String)]

    private var allMachines: Binding<Bool> {
        Binding(
            get: { command.targets == .all },
            set: { command.targets = $0 ? .all : .machines([]) }
        )
    }

    private var workingDirectory: Binding<String> {
        Binding(
            get: { command.workingDirectory ?? "" },
            set: { command.workingDirectory = $0.isEmpty ? nil : $0 }
        )
    }

    private func isSelected(_ home: String) -> Binding<Bool> {
        Binding(
            get: {
                if case .machines(let homes) = command.targets { return homes.contains(home) }
                return false
            },
            set: { selected in
                guard case .machines(var homes) = command.targets else { return }
                homes.removeAll { $0 == home }
                if selected { homes.append(home) }
                command.targets = .machines(homes)
            }
        )
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $command.name, prompt: Text("Restart Apache"))
                LabeledContent("Command") {
                    TextField("Command", text: $command.command, prompt: Text("sudo systemctl restart apache2"))
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Working directory") {
                    TextField("Working directory", text: workingDirectory, prompt: Text("Optional"))
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Command")
            } footer: {
                Text("Runs inside the VM with `vagrant ssh -c` as the SSH user. Prefix with `sudo` when root is needed. When a working directory is set, the command runs there.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle("All machines", isOn: allMachines)
                if command.targets != .all {
                    if machines.isEmpty {
                        Text("No Vagrant machines found.")
                            .foregroundColor(.secondary)
                    }
                    ForEach(machines, id: \.home) { machine in
                        Toggle(isOn: isSelected(machine.home)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(machine.name)
                                Text(machine.home)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            } header: {
                Text("Run On")
            } footer: {
                Text("The command appears in the menu of these machines, between Reload and SSH.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
