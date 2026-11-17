import XCTest
@testable import VagrantCore

final class CustomCommandTests: XCTestCase {
    private let machine = VagrantMachine(id: "7ae2403", home: "/Users/me/repos/web-app", state: "running")

    // MARK: - Shell quoting

    func testShellQuotedPlain() {
        XCTAssertEqual(VagrantClient.shellQuoted("/var/www"), "'/var/www'")
    }

    func testShellQuotedSpaces() {
        XCTAssertEqual(VagrantClient.shellQuoted("/var/my app"), "'/var/my app'")
    }

    func testShellQuotedSingleQuote() {
        XCTAssertEqual(VagrantClient.shellQuoted("it's"), #"'it'\''s'"#)
    }

    // MARK: - Targets

    func testAllTargetsAppliesToEveryMachine() {
        let command = CustomCommand(name: "A", command: "true", targets: .all)
        XCTAssertTrue(command.applies(to: machine))
    }

    func testSelectedTargetMatchesHomePath() {
        let command = CustomCommand(name: "A", command: "true", targets: .machines(["/Users/me/repos/web-app"]))
        XCTAssertTrue(command.applies(to: machine))
    }

    func testSelectedTargetIgnoresOtherMachines() {
        let command = CustomCommand(name: "A", command: "true", targets: .machines(["/Users/me/repos/other"]))
        XCTAssertFalse(command.applies(to: machine))
    }

    func testEmptySelectionMatchesNothing() {
        let command = CustomCommand(name: "A", command: "true", targets: .machines([]))
        XCTAssertFalse(command.applies(to: machine))
    }

    func testMachineWithoutHomeNeverMatchesSelection() {
        let command = CustomCommand(name: "A", command: "true", targets: .machines([""]))
        XCTAssertFalse(command.applies(to: VagrantMachine(id: "x")))
    }

    // MARK: - Completeness

    func testCompleteCommand() {
        XCTAssertTrue(CustomCommand(name: "A", command: "ls").isComplete)
    }

    func testBlankNameOrCommandIsIncomplete() {
        XCTAssertFalse(CustomCommand(name: " ", command: "ls").isComplete)
        XCTAssertFalse(CustomCommand(name: "A", command: "  \n").isComplete)
    }

    // MARK: - SSH arguments

    func testArgumentsWithoutWorkingDirectory() {
        let command = CustomCommand(name: "Restart Apache", command: "sudo systemctl restart apache2")
        XCTAssertEqual(command.sshArguments(for: machine),
                       ["ssh", "7ae2403", "-c", "sudo systemctl restart apache2"])
    }

    func testArgumentsWithWorkingDirectory() {
        let command = CustomCommand(name: "Migrate", command: "php artisan migrate", workingDirectory: "/var/www/app")
        XCTAssertEqual(command.sshArguments(for: machine),
                       ["ssh", "7ae2403", "-c", "cd '/var/www/app' && php artisan migrate"])
    }

    func testWorkingDirectoryIsQuoted() {
        let command = CustomCommand(name: "Ls", command: "ls", workingDirectory: "/var/it's here")
        XCTAssertEqual(command.sshArguments(for: machine).last, #"cd '/var/it'\''s here' && ls"#)
    }

    func testBlankWorkingDirectoryIsIgnored() {
        let command = CustomCommand(name: "Ls", command: "ls", workingDirectory: "   ")
        XCTAssertEqual(command.sshArguments(for: machine).last, "ls")
    }

    func testWorkingDirectoryIsTrimmed() {
        let command = CustomCommand(name: "Ls", command: "ls", workingDirectory: " /tmp \n")
        XCTAssertEqual(command.sshArguments(for: machine).last, "cd '/tmp' && ls")
    }
}

final class CustomCommandStoreTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "CustomCommandStoreTests-\(UUID().uuidString)")!
    }

    func testEmptyStoreReturnsNoCommands() {
        XCTAssertEqual(CustomCommandStore(defaults: freshDefaults()).load(), [])
    }

    func testSaveThenLoadRoundTrips() {
        let defaults = freshDefaults()
        let commands = [
            CustomCommand(name: "Restart Apache", command: "sudo systemctl restart apache2"),
            CustomCommand(name: "Migrate", command: "php artisan migrate", workingDirectory: "/var/www",
                          targets: .machines(["/Users/me/a", "/Users/me/b"])),
        ]
        CustomCommandStore(defaults: defaults).save(commands)
        XCTAssertEqual(CustomCommandStore(defaults: defaults).load(), commands)
    }

    func testCorruptDataLoadsAsEmpty() {
        let defaults = freshDefaults()
        defaults.set(Data("not json".utf8), forKey: CustomCommandStore.key)
        XCTAssertEqual(CustomCommandStore(defaults: defaults).load(), [])
    }
}
