import Darwin
import Foundation

/// Runs a program on a pseudo-terminal, so programs that need a terminal (sudo asking
/// for a password, `[y/N]` confirmations) work, and the caller can answer them.
/// stdout and stderr share the terminal, so output arrives as one stream in order.
public final class PTYRunner: @unchecked Sendable {
    public let executable: String
    public let arguments: [String]
    public let directory: String?
    public let environment: [String: String]?

    private let lock = NSLock()
    private var master: Int32 = -1
    private var pid: pid_t = 0

    public init(executable: String, arguments: [String], directory: String? = nil,
                environment: [String: String]? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
    }

    /// Starts the program and blocks until it exits and its output is drained.
    /// `onOutput` is called on the calling thread with each chunk of output.
    /// Returns the exit status (128 + signal number when it was killed by a signal).
    public func run(onOutput: (String) -> Void) throws -> Int32 {
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else { throw Self.posixError(errno) }
        // The child opens the slave by name after setsid, which makes it the controlling terminal.
        let slaveName = String(cString: ttyname(slaveFD))
        let childPID: pid_t
        do {
            childPID = try spawn(slavePath: slaveName)
        } catch {
            close(masterFD)
            close(slaveFD)
            throw error
        }
        // Keep the slave open until the child has it, then drop ours so reads end with EIO on exit.
        close(slaveFD)
        lock.lock()
        master = masterFD
        pid = childPID
        lock.unlock()

        var decoder = UTF8ChunkDecoder()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(masterFD, &buffer, buffer.count)
            if count > 0 {
                let text = decoder.decode(buffer[0..<count])
                if !text.isEmpty { onOutput(text) }
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break // EOF or EIO: every process holding the terminal has exited.
            }
        }

        var status: Int32 = 0
        while waitpid(childPID, &status, 0) == -1 && errno == EINTR {}

        lock.lock()
        master = -1
        lock.unlock()
        close(masterFD)

        // WIFEXITED / WEXITSTATUS / WTERMSIG are macros Swift can't import.
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    /// Types `text` into the program's terminal, e.g. "secret\n". Ignored when not running.
    public func send(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard master >= 0 else { return }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(master, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 { if errno == EINTR { continue }; return }
                offset += written
            }
        }
    }

    /// Asks the program (and the processes it started on the terminal) to stop.
    public func terminate() {
        lock.lock()
        defer { lock.unlock() }
        guard master >= 0, pid > 0 else { return }
        // The child leads its own session and process group, so signal the whole group.
        kill(-pid, SIGTERM)
    }

    private func spawn(slavePath: String) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        if let directory, !directory.isEmpty {
            posix_spawn_file_actions_addchdir_np(&actions, directory)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Reset signals the app may have changed (SIGPIPE is ignored by default in Swift tools).
        var defaults = sigset_t()
        sigfillset(&defaults)
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &empty)
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))

        let env = (environment ?? ProcessInfo.processInfo.environment).map { "\($0.key)=\($0.value)" }
        let argv = [executable] + arguments
        var childPID: pid_t = 0
        let result = withCStrings(argv) { argvPointer in
            withCStrings(env) { envPointer in
                posix_spawn(&childPID, executable, &actions, &attributes, argvPointer, envPointer)
            }
        }
        guard result == 0 else { throw Self.posixError(result) }
        return childPID
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

/// Calls `body` with a NULL-terminated C array of `strings`.
private func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.forEach { free($0) } }
    return body(pointers)
}

/// Decodes UTF-8 that arrives in chunks, holding back a multi-byte character split
/// across two reads instead of turning it into replacement characters.
struct UTF8ChunkDecoder {
    private var pending: [UInt8] = []

    mutating func decode<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        pending.append(contentsOf: bytes)
        var cut = pending.count
        // Look back at most 3 bytes for the start of an unfinished character.
        for back in 1...min(3, pending.count) {
            let byte = pending[pending.count - back]
            if byte & 0xC0 == 0x80 { continue } // continuation byte
            let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            if length > back { cut = pending.count - back }
            break
        }
        let text = String(decoding: pending[0..<cut], as: UTF8.self)
        pending.removeFirst(cut)
        return text
    }
}
