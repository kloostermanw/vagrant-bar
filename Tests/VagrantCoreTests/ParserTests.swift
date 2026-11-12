import XCTest
@testable import VagrantCore

final class ParserTests: XCTestCase {
    let sample = """
    1794487934,,metadata,machine-count,4
    1794487934,,machine-id,636216e
    1794487934,,provider-name,vmware_desktop
    1794487934,,machine-home,/Users/wiebe/repos/celery-web-app-dev2
    1794487934,,state,not running
    1794487934,,machine-id,e5105ca
    1794487934,,provider-name,vmware_desktop
    1794487934,,machine-home,/Users/wiebe/repos/dev3/celery-web-app-dev3
    1794487934,,state,not running
    1794487934,,machine-id,7ae2403
    1794487934,,provider-name,vmware_desktop
    1794487934,,machine-home,/Users/wiebe/repos/celery-web-app
    1794487934,,state,running
    1794487934,,machine-id,abc86ca
    1794487934,,provider-name,vmware_desktop
    1794487934,,machine-home,/Users/wiebe/repos/celery-web-app-dev1
    1794487934,,state,not running
    1794487934,,ui,info,id
    1794487934,,ui,info,7ae2403
    1794487934,,ui,info,running
    """

    func testParsesSample() {
        let machines = VagrantClient.parse(sample)
        XCTAssertEqual(machines.count, 4)
        XCTAssertEqual(machines.map(\.name),
                       ["celery-web-app-dev2", "celery-web-app-dev3", "celery-web-app", "celery-web-app-dev1"])
        XCTAssertEqual(machines.filter(\.isRunning).map(\.id), ["7ae2403"])
        XCTAssertEqual(machines[0].provider, "vmware_desktop")
    }

    func testCommaInPath() {
        let out = """
        1,,machine-id,aaa
        1,,machine-home,/tmp/a%!(VAGRANT_COMMA)b,c
        1,,state,poweroff
        """
        let machines = VagrantClient.parse(out)
        XCTAssertEqual(machines, [VagrantMachine(id: "aaa", home: "/tmp/a,b,c", state: "poweroff")])
        XCTAssertFalse(machines[0].isRunning)
    }

    func testEmptyOutput() {
        XCTAssertEqual(VagrantClient.parse(""), [])
    }
}
