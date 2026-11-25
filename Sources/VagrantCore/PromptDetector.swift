import Foundation

/// A question the running command is waiting on.
public enum Prompt: Equatable, Sendable {
    /// Input that should not be shown, like sudo's password.
    case password(String)
    case text(String)

    public var line: String {
        switch self {
        case .password(let line), .text(let line): return line
        }
    }
}

public enum PromptDetector {
    /// Guesses whether `output` ends in a prompt. Only the unfinished last line counts:
    /// Vagrant ends its progress messages with a newline, while a prompt waits on its line.
    /// Call this once the output has gone quiet, so a line still being written isn't mistaken.
    public static func prompt(in output: String) -> Prompt? {
        let last = output.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        let line = last.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }

        let lower = line.lowercased()
        if lower.contains("password") || lower.contains("passphrase") {
            return .password(line)
        }
        let isQuestion = line.hasSuffix(":") || line.hasSuffix("?")
            || lower.hasSuffix("[y/n]") || lower.hasSuffix("(yes/no)")
        return isQuestion ? .text(line) : nil
    }
}
