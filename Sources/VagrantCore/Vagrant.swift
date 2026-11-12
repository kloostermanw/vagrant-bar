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

        var env = ProcessInfo.processInfo.environment
        let extra = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = env["PATH"].map { "\(extra):\($0)" } ?? extra
        process.environment = env

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

    public static func tail(_ text: String, lines: Int = 15) -> String {
        text.split(whereSeparator: \.isNewline).suffix(lines).joined(separator: "\n")
    }
}
