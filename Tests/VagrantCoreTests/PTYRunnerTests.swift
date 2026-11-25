import XCTest
@testable import VagrantCore

final class PTYRunnerTests: XCTestCase {
    /// Collects output chunks from a background thread.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [String] = []
        func append(_ chunk: String) { lock.lock(); chunks.append(chunk); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return chunks.joined() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return chunks.count }
    }

    private func sh(_ script: String) -> PTYRunner {
        PTYRunner(executable: "/bin/sh", arguments: ["-c", script])
    }

    func testReturnsOutputAndExitStatus() throws {
        let output = Collector()
        let status = try sh("echo hello; exit 3").run { output.append($0) }
        XCTAssertEqual(status, 3)
        XCTAssertEqual(output.text, "hello\r\n")
    }

    func testProcessHasATerminal() throws {
        // sudo refuses to ask for a password without one: the reason for the pty.
        let output = Collector()
        let status = try sh("[ -t 0 ] && [ -t 1 ] && echo tty").run { output.append($0) }
        XCTAssertEqual(status, 0)
        XCTAssertEqual(output.text, "tty\r\n")
    }

    func testTerminalIsTheControllingTerminal() throws {
        // sudo opens /dev/tty, which only works when the pty is the controlling terminal.
        let output = Collector()
        let status = try sh("echo via-tty > /dev/tty").run { output.append($0) }
        XCTAssertEqual(status, 0)
        XCTAssertEqual(output.text, "via-tty\r\n")
    }

    func testStderrIsCaptured() throws {
        let output = Collector()
        _ = try sh("echo oops >&2").run { output.append($0) }
        XCTAssertEqual(output.text, "oops\r\n")
    }

    func testDeliversOutputWhileRunning() throws {
        let runner = sh("echo first; read x; echo second")
        let output = Collector()
        let sawFirst = expectation(description: "first chunk before the process exits")
        let done = expectation(description: "exit")
        DispatchQueue.global().async {
            _ = try? runner.run { chunk in
                output.append(chunk)
                if chunk.contains("first") { sawFirst.fulfill() }
            }
            done.fulfill()
        }
        wait(for: [sawFirst], timeout: 5)
        XCTAssertFalse(output.text.contains("second"))
        runner.send("\n")
        wait(for: [done], timeout: 5)
        XCTAssertTrue(output.text.contains("second"))
    }

    func testSendsInputToTheProcess() throws {
        let runner = sh("stty -echo; printf 'Password: '; read x; stty echo; echo; echo got:$x")
        let output = Collector()
        let prompted = expectation(description: "prompt")
        let done = expectation(description: "exit")
        var status: Int32?
        DispatchQueue.global().async {
            status = try? runner.run { chunk in
                output.append(chunk)
                if chunk.contains("Password:") { prompted.fulfill() }
            }
            done.fulfill()
        }
        wait(for: [prompted], timeout: 5)
        runner.send("secret\n")
        wait(for: [done], timeout: 5)
        XCTAssertEqual(status, 0)
        XCTAssertTrue(output.text.contains("got:secret"))
        // Echo was off, so the typed password appears only in the script's own echo.
        XCTAssertEqual(output.text.components(separatedBy: "secret").count, 2, output.text)
    }

    func testTerminateStopsTheProcess() throws {
        let runner = sh("echo started; sleep 30")
        let started = expectation(description: "started")
        let done = expectation(description: "exit")
        DispatchQueue.global().async {
            _ = try? runner.run { if $0.contains("started") { started.fulfill() } }
            done.fulfill()
        }
        wait(for: [started], timeout: 5)
        runner.terminate()
        wait(for: [done], timeout: 5)
    }

    func testRunsInDirectoryWithEnvironment() throws {
        let runner = PTYRunner(executable: "/bin/sh", arguments: ["-c", "pwd; echo $FOO"],
                               directory: "/tmp", environment: ["FOO": "bar"])
        let output = Collector()
        _ = try runner.run { output.append($0) }
        XCTAssertTrue(output.text.hasSuffix("tmp\r\nbar\r\n"), output.text)
    }

    func testDecoderHoldsBackSplitCharacter() {
        var decoder = UTF8ChunkDecoder()
        let bytes = Array("a→b".utf8) // → is 3 bytes
        XCTAssertEqual(decoder.decode(bytes[0..<2]), "a")
        XCTAssertEqual(decoder.decode(bytes[2..<3]), "")
        XCTAssertEqual(decoder.decode(bytes[3...]), "→b")
    }

    func testMissingExecutableThrows() {
        XCTAssertThrowsError(try PTYRunner(executable: "/nonexistent/bin", arguments: []).run { _ in })
    }
}

final class InteractiveClientTests: XCTestCase {
    // /bin/sh stands in for the vagrant binary.
    let client = VagrantClient(binary: "/bin/sh")

    func testRunsWithoutColorAndWithExtendedPath() throws {
        let runner = try client.interactiveRunner(["-c", "echo $VAGRANT_NO_COLOR; echo $PATH"], in: "/tmp")
        let result = try VagrantClient.run(runner) { _ in }
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.hasPrefix("1\r\n/usr/local/bin:/opt/homebrew/bin:"), result.stdout)
        XCTAssertEqual(runner.directory, "/tmp")
    }

    func testResultHoldsAllOutputInOrder() throws {
        let runner = try client.interactiveRunner(["-c", "echo out; echo err >&2; exit 2"])
        var chunks: [String] = []
        let result = try VagrantClient.run(runner) { chunks.append($0) }
        XCTAssertEqual(result.status, 2)
        XCTAssertEqual(result.stdout, "out\r\nerr\r\n")
        XCTAssertEqual(result.stdout, chunks.joined())
        XCTAssertEqual(result.stderr, "")
    }

    func testMissingBinaryThrows() {
        XCTAssertThrowsError(try VagrantClient(binary: "/nonexistent/vagrant").interactiveRunner(["up"])) { error in
            guard case VagrantError.missingBinary = error else { return XCTFail("\(error)") }
        }
    }
}
