import XCTest
@testable import VagrantCore

final class ProcessTests: XCTestCase {
    let machines = [
        VagrantMachine(id: "7ae2403", home: "/Users/w/repos/celery-web-app", state: "running"),
        VagrantMachine(id: "abc86ca", home: "/Users/w/repos/celery-web-app-dev1", state: "running"),
        VagrantMachine(id: "636216e", home: "/Users/w/repos/celery-web-app-dev2", state: "not running"),
    ]

    func testParsesLauncherAndRubyProcesses() {
        let ps = """
          865 /opt/vagrant-vmware-desktop/bin/vagrant-vmware-utility api -port=9922
        60025 vagrant up --provision
        60061 ruby /opt/vagrant/embedded/gems/gems/vagrant-2.4.9/bin/vagrant up --provision
        60665 /Applications/VagrantBar.app/Contents/MacOS/VagrantBar
        70000 /usr/local/bin/vagrant halt abc86ca
        70001 /bin/zsh -c cat > /tmp/fake/vagrant && vagrant up
        70002 /opt/vagrant/embedded/bin/ruby /opt/vagrant/embedded/gems/gems/vagrant-2.4.9/bin/vagrant reload
        """
        let processes = VagrantProcesses.parse(ps)
        XCTAssertEqual(processes.map(\.pid), [60025, 60061, 70000, 70002])
        XCTAssertEqual(processes[0].arguments, ["up", "--provision"])
        XCTAssertEqual(processes[2].subcommand, "halt")
    }

    func testSshAndStatusDoNotTakeTheLock() {
        XCTAssertFalse(VagrantProcess(pid: 1, arguments: ["ssh", "-c", "phpunit"]).takesMachineLock)
        XCTAssertFalse(VagrantProcess(pid: 1, arguments: ["global-status", "--machine-readable"]).takesMachineLock)
        XCTAssertFalse(VagrantProcess(pid: 1, arguments: ["--version"]).takesMachineLock)
        XCTAssertTrue(VagrantProcess(pid: 1, arguments: ["up"]).takesMachineLock)
        XCTAssertTrue(VagrantProcess(pid: 1, arguments: ["--debug", "reload"]).takesMachineLock)
    }

    func testParsesLsofCwds() {
        let lsof = "p60025\nfcwd\nn/Users/w/repos/celery-web-app-dev1\np60061\nfcwd\nn/Users/w/my repo\n"
        XCTAssertEqual(VagrantProcesses.parseCwds(lsof),
                       [60025: "/Users/w/repos/celery-web-app-dev1", 60061: "/Users/w/my repo"])
    }

    func testBusyByFolderOrIdButNotSsh() {
        let processes = [
            // `vagrant up` in dev1's folder
            VagrantProcess(pid: 1, arguments: ["up"], cwd: "/Users/w/repos/celery-web-app-dev1"),
            // `vagrant ssh` in celery-web-app's folder: no lock, not busy
            VagrantProcess(pid: 2, arguments: ["ssh", "-c", "phpunit"], cwd: "/Users/w/repos/celery-web-app"),
            // `vagrant halt <id>` from anywhere
            VagrantProcess(pid: 3, arguments: ["halt", "636216e"], cwd: "/Users/w"),
        ]
        XCTAssertEqual(VagrantProcesses.busyMachineIDs(machines, processes: processes), ["abc86ca", "636216e"])
    }

    func testSubfolderCountsButSiblingPrefixDoesNot() {
        let inSub = [VagrantProcess(pid: 1, arguments: ["provision"], cwd: "/Users/w/repos/celery-web-app/src")]
        XCTAssertEqual(VagrantProcesses.busyMachineIDs(machines, processes: inSub), ["7ae2403"])
        // "/celery-web-app-dev1" starts with "/celery-web-app" but is a different folder
        let sibling = [VagrantProcess(pid: 1, arguments: ["up"], cwd: "/Users/w/repos/celery-web-app-dev1")]
        XCTAssertEqual(VagrantProcesses.busyMachineIDs(machines, processes: sibling), ["abc86ca"])
    }

    func testDetectsLockError() {
        let msg = "An action 'halt' was attempted on the machine 'celery',\nbut another process is already executing an action on\nthe machine."
        XCTAssertTrue(VagrantClient.isMachineLockedError(msg))
        XCTAssertTrue(VagrantClient.isMachineLockedError("but another process is already\nexecuting an action on"))
        XCTAssertFalse(VagrantClient.isMachineLockedError("The provider 'vmware_desktop' could not be found"))
    }
}
