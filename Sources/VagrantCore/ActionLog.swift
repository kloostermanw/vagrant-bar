import Foundation

/// The output of an action started from the menu (Up, Halt, Reload, a custom command),
/// cleaned up from raw terminal output into plain text.
public struct ActionLog: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case running
        case exited(Int32)
        /// The user stopped the command from the log window.
        case stopped
        case couldNotStart(String)
    }

    public let command: String
    public let startedAt: Date
    public var status: Status = .running
    public private(set) var text = ""
    /// A `\r` at the end of a chunk: either half of `\r\n` or a line redraw.
    private var pendingCarriageReturn = false

    public init(command: String, startedAt: Date = Date()) {
        self.command = command
        self.startedAt = startedAt
    }

    public var statusDescription: String {
        switch status {
        case .running: return "Running"
        case .exited(0): return "Finished"
        case .exited(let code): return "Failed (exit status \(code))"
        case .stopped: return "Stopped"
        case .couldNotStart(let message): return "Could not start: \(message)"
        }
    }

    public mutating func append(_ chunk: String) {
        let plain = chunk.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        for character in plain {
            if pendingCarriageReturn {
                pendingCarriageReturn = false
                if character == "\n" {
                    text.append("\n")
                    continue
                }
                // A lone \r returns to the start of the line: the next text replaces it.
                if let newline = text.lastIndex(of: "\n") {
                    text.removeSubrange(text.index(after: newline)...)
                } else {
                    text.removeAll()
                }
            }
            // Swift treats "\r\n" as a single Character.
            if character == "\r\n" {
                text.append("\n")
            } else if character == "\r" {
                pendingCarriageReturn = true
            } else {
                text.append(character)
            }
        }
    }
}
