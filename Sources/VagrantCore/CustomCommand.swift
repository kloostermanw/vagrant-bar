import Foundation

/// A user-defined shell command run inside a Vagrant machine over `vagrant ssh -c`.
public struct CustomCommand: Codable, Equatable, Identifiable, Sendable {
    public enum Targets: Codable, Equatable, Sendable {
        case all
        /// Machines identified by their home (Vagrantfile folder) path. The Vagrant
        /// machine id changes when a VM is recreated; the folder does not.
        case machines([String])
    }

    public var id: UUID
    public var name: String
    public var command: String
    /// Directory inside the VM to run the command in; nil or blank runs it in the SSH user's home.
    public var workingDirectory: String?
    public var targets: Targets

    public init(id: UUID = UUID(), name: String, command: String,
                workingDirectory: String? = nil, targets: Targets = .all) {
        self.id = id
        self.name = name
        self.command = command
        self.workingDirectory = workingDirectory
        self.targets = targets
    }

    /// A command needs a name for its menu item and something to run; an empty
    /// `vagrant ssh -c ""` would behave like an interactive login.
    public var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func applies(to machine: VagrantMachine) -> Bool {
        switch targets {
        case .all:
            return true
        case .machines(let homes):
            return !machine.home.isEmpty && homes.contains(machine.home)
        }
    }

    /// The script passed to `vagrant ssh -c`. `&&` keeps the command from running
    /// somewhere else when the working directory doesn't exist.
    public var script: String {
        let directory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return directory.isEmpty ? command : "cd \(VagrantClient.shellQuoted(directory)) && \(command)"
    }

    public func sshArguments(for machine: VagrantMachine) -> [String] {
        ["ssh", machine.id, "-c", script]
    }
}

/// Persists custom commands as JSON in UserDefaults.
public struct CustomCommandStore {
    public static let key = "customCommands"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [CustomCommand] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([CustomCommand].self, from: data)) ?? []
    }

    public func save(_ commands: [CustomCommand]) {
        guard let data = try? JSONEncoder().encode(commands) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
