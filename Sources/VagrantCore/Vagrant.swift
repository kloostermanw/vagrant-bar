import Foundation

public struct VagrantMachine: Equatable, Sendable {
    public var id: String
    public var provider: String = ""
    public var home: String = ""
    public var state: String = ""

    public init(id: String, provider: String = "", home: String = "", state: String = "") {
        self.id = id
        self.provider = provider
        self.home = home
        self.state = state
    }

    public var isRunning: Bool { state == "running" }

    public var name: String {
        home.isEmpty ? id : URL(fileURLWithPath: home).lastPathComponent
    }
}

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum VagrantError: LocalizedError {
    case missingBinary(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .missingBinary(let path): return "Vagrant not found at \(path)"
        case .failed(let message): return message
        }
    }
}

public struct VagrantClient: Sendable {
    public let binary: String

    public init(binary: String = "/usr/local/bin/vagrant") {
        self.binary = binary
    }

    /// Parses `vagrant global-status --machine-readable` output.
    /// Format per line: timestamp,target,type,data... (data may contain commas).
    public static func parse(_ output: String) -> [VagrantMachine] {
        var machines: [VagrantMachine] = []
        var current: VagrantMachine?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let parts = rawLine.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4 else { continue }
            let key = String(parts[2])
            let value = String(parts[3])
                .replacingOccurrences(of: "%!(VAGRANT_COMMA)", with: ",")
                .replacingOccurrences(of: "\\n", with: "\n")

            switch key {
            case "machine-id":
                if let m = current { machines.append(m) }
                current = VagrantMachine(id: value)
            case "provider-name":
                current?.provider = value
            case "machine-home":
                current?.home = value
            case "state":
                current?.state = value
            default:
                continue
            }
        }
        if let m = current { machines.append(m) }
        return machines
    }

    public func globalStatus() throws -> [VagrantMachine] {
        let result = try run(["global-status", "--machine-readable"])
        guard result.status == 0 else {
            throw VagrantError.failed(Self.tail(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
        return Self.parse(result.stdout)
    }

    public func run(_ arguments: [String], in directory: String? = nil) throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw VagrantError.missingBinary(binary)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        if let directory, !directory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }

        process.environment = Self.environment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        try process.run()
        // Read both pipes concurrently so a full buffer can't deadlock the child.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Prepares `vagrant <arguments>` to run on a pseudo-terminal, so prompts such as
    /// sudo's password request for NFS exports can be answered through the runner.
    public func interactiveRunner(_ arguments: [String], in directory: String? = nil) throws -> PTYRunner {
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw VagrantError.missingBinary(binary)
        }
        var env = Self.environment()
        // Vagrant colors its output on a terminal; the log shows plain text.
        env["VAGRANT_NO_COLOR"] = "1"
        return PTYRunner(executable: binary, arguments: arguments, directory: directory, environment: env)
    }

    /// Runs `runner` to completion, passing output along as it arrives. The terminal
    /// merges stdout and stderr, so the result carries all output in `stdout`.
    public static func run(_ runner: PTYRunner, onOutput: (String) -> Void) throws -> CommandResult {
        var output = ""
        let status = try runner.run { chunk in
            output += chunk
            onOutput(chunk)
        }
        return CommandResult(status: status, stdout: output, stderr: "")
    }

    /// The app's environment, with the usual install locations on PATH: an app started
    /// from Finder doesn't get the user's shell PATH.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = env["PATH"].map { "\(extra):\($0)" } ?? extra
        return env
    }

    /// Wraps `text` in single quotes for a POSIX shell.
    public static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func tail(_ text: String, lines: Int = 15) -> String {
        text.split(whereSeparator: \.isNewline).suffix(lines).joined(separator: "\n")
    }
}
