import Foundation

/// A vagrant command running somewhere on the system (terminal, another app, ...).
public struct VagrantProcess: Equatable {
    public let pid: Int32
    /// Arguments after the `vagrant` executable, e.g. ["up", "abc86ca"].
    public let arguments: [String]
    public var cwd: String?

    public init(pid: Int32, arguments: [String], cwd: String? = nil) {
        self.pid = pid
        self.arguments = arguments
        self.cwd = cwd
    }

    public var subcommand: String? {
        arguments.first { !$0.hasPrefix("-") }
    }

    /// Whether this command takes Vagrant's per-machine lock. Vagrant skips the
    /// lock for ssh actions (machine.rb), and the read-only commands never take it.
    public var takesMachineLock: Bool {
        guard let subcommand else { return false }
        let nonLocking: Set<String> = [
            "ssh", "ssh-config", "status", "global-status", "version", "help",
            "box", "plugin", "cloud", "login", "init", "validate", "list-commands", "port",
        ]
        return !nonLocking.contains(subcommand)
    }
}

public enum VagrantProcesses {
    /// Parses `ps -Ao pid=,command=` output into vagrant invocations. Both the
    /// launcher (`vagrant up`) and its ruby child (`ruby .../bin/vagrant up`) match;
    /// that is harmless because they share the same cwd and arguments.
    public static func parse(_ psOutput: String) -> [VagrantProcess] {
        psOutput.split(whereSeparator: \.isNewline).compactMap { line in
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard tokens.count >= 2, let pid = Int32(tokens[0]) else { return nil }
            let command = Array(tokens.dropFirst())
            let name = { (token: String) in (token as NSString).lastPathComponent }
            // `vagrant` must be the executable itself, or the script ruby runs.
            // A shell whose arguments merely mention a .../vagrant path must not match.
            let index: Int
            if name(command[0]) == "vagrant" {
                index = 0
            } else if name(command[0]).hasPrefix("ruby"), command.count > 1, name(command[1]) == "vagrant" {
                index = 1
            } else {
                return nil
            }
            return VagrantProcess(pid: pid, arguments: Array(command[(index + 1)...]))
        }
    }

    /// Parses `lsof -a -d cwd -Fn -p ...` output into pid -> cwd.
    public static func parseCwds(_ lsofOutput: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        var pid: Int32?
        for line in lsofOutput.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let pid {
                result[pid] = String(line.dropFirst())
            }
        }
        return result
    }

    /// Machine ids that a lock-taking vagrant command is working on: either it runs
    /// inside the machine's folder, or it names the machine id as an argument.
    public static func busyMachineIDs(_ machines: [VagrantMachine], processes: [VagrantProcess]) -> Set<String> {
        var busy: Set<String> = []
        for process in processes where process.takesMachineLock {
            for machine in machines {
                if process.arguments.contains(machine.id) {
                    busy.insert(machine.id)
                } else if let cwd = process.cwd, !machine.home.isEmpty,
                          cwd == machine.home || cwd.hasPrefix(machine.home + "/") {
                    busy.insert(machine.id)
                }
            }
        }
        return busy
    }

    /// Lists running vagrant commands with their working directories.
    public static func running() -> [VagrantProcess] {
        guard let ps = try? capture("/bin/ps", ["-Ao", "pid=,command="]) else { return [] }
        var processes = parse(ps).filter { $0.takesMachineLock }
        guard !processes.isEmpty else { return [] }

        let pids = processes.map { String($0.pid) }.joined(separator: ",")
        if let lsof = try? capture("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn", "-p", pids]) {
            let cwds = parseCwds(lsof)
            for i in processes.indices {
                processes[i].cwd = cwds[processes[i].pid]
            }
        }
        return processes
    }

    private static func capture(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

extension VagrantClient {
    /// True when vagrant refused an action because another process holds the machine lock.
    public static func isMachineLockedError(_ output: String) -> Bool {
        // Vagrant hard-wraps its messages, so compare with whitespace collapsed.
        let flat = output.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.contains("another process is already executing an action")
    }
}
