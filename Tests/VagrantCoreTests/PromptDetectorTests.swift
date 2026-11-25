import XCTest
@testable import VagrantCore

final class PromptDetectorTests: XCTestCase {
    func testSudoPasswordFromIssue() {
        let output = """
        ==> server: Exporting NFS shared folders...
        ==> server: Preparing to edit /etc/exports. Administrator privileges will be required...
        [sudo] password for wiebe:\u{20}
        """
        XCTAssertEqual(PromptDetector.prompt(in: output), .password("[sudo] password for wiebe:"))
    }

    func testMacSudoAndPassphrasePrompts() {
        XCTAssertEqual(PromptDetector.prompt(in: "Password:"), .password("Password:"))
        XCTAssertEqual(PromptDetector.prompt(in: "x\nEnter passphrase for key '/k': "),
                       .password("Enter passphrase for key '/k':"))
    }

    func testQuestionsAreTextPrompts() {
        XCTAssertEqual(PromptDetector.prompt(in: "default: Are you sure you want to destroy the 'default' VM? [y/N] "),
                       .text("default: Are you sure you want to destroy the 'default' VM? [y/N]"))
        XCTAssertEqual(PromptDetector.prompt(in: "1) virtualbox\n2) vmware_desktop\n\nEnter your choice: "),
                       .text("Enter your choice:"))
        XCTAssertEqual(PromptDetector.prompt(in: "Continue (yes/no)"), .text("Continue (yes/no)"))
    }

    func testFinishedLinesAreNotPrompts() {
        // Every Vagrant progress message ends with a newline; a prompt waits on its line.
        XCTAssertNil(PromptDetector.prompt(in: "[sudo] password for wiebe:\n"))
        XCTAssertNil(PromptDetector.prompt(in: "Are you sure?\n"))
        XCTAssertNil(PromptDetector.prompt(in: ""))
        XCTAssertNil(PromptDetector.prompt(in: "done\n   "))
    }

    func testUnfinishedProgressIsNotAPrompt() {
        XCTAssertNil(PromptDetector.prompt(in: "==> server: Booting VM..."))
        XCTAssertNil(PromptDetector.prompt(in: "    server: Progress: 55% (Rate: 12.3M/s, Estimated time remaining: 0:01:02)"))
        XCTAssertNil(PromptDetector.prompt(in: "    server: SSH address: 127.0.0.1:2222"))
    }
}
