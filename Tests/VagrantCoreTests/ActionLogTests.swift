import XCTest
@testable import VagrantCore

final class ActionLogTests: XCTestCase {
    private func log(_ chunks: String...) -> ActionLog {
        var log = ActionLog(command: "vagrant up", startedAt: Date(timeIntervalSince1970: 0))
        chunks.forEach { log.append($0) }
        return log
    }

    func testStartsRunningAndEmpty() {
        let log = log()
        XCTAssertEqual(log.status, .running)
        XCTAssertEqual(log.text, "")
        XCTAssertEqual(log.statusDescription, "Running")
    }

    func testTerminalLineEndingsBecomeNewlines() {
        XCTAssertEqual(log("==> server: Booting\r\n", "done\r\n").text, "==> server: Booting\ndone\n")
    }

    func testLineEndingSplitAcrossChunks() {
        XCTAssertEqual(log("one\r", "\ntwo\r\n").text, "one\ntwo\n")
    }

    func testCarriageReturnRedrawsTheLine() {
        // Box downloads redraw a progress line with \r.
        let log = log("start\n", "Progress: 10%\r", "Progress: 55%\r", "Progress: 100%\r\n", "end\n")
        XCTAssertEqual(log.text, "start\nProgress: 100%\nend\n")
    }

    func testStripsAnsiEscapes() {
        XCTAssertEqual(log("\u{1B}[0;32m==> ok\u{1B}[0m\r\n", "\u{1B}[KProgress\r\n").text, "==> ok\nProgress\n")
    }

    func testStatusDescriptions() {
        var log = log()
        log.status = .exited(0)
        XCTAssertEqual(log.statusDescription, "Finished")
        log.status = .exited(1)
        XCTAssertEqual(log.statusDescription, "Failed (exit status 1)")
        log.status = .stopped
        XCTAssertEqual(log.statusDescription, "Stopped")
        log.status = .couldNotStart("Vagrant not found at /x")
        XCTAssertEqual(log.statusDescription, "Could not start: Vagrant not found at /x")
    }
}
