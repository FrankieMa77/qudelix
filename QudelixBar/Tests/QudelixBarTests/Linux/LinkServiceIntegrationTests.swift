#if os(Linux)
import XCTest
import Glibc
@testable import QudelixBar

final class LinkServiceIntegrationTests: XCTestCase {
    private var harness: ServiceHarness!
    private var foreignLock: QxInstanceLock?

    override func setUp() {
        super.setUp()
        harness = ServiceHarness(transport: QxFixtures.answeringLink(kind: .bluetooth))
    }

    override func tearDown() {
        foreignLock?.release()
        foreignLock = nil
        if harness.status == nil { harness.stop() }
        harness.cleanUp()
        harness = nil
        super.tearDown()
    }

    private func serviceLink(spawn: @escaping () -> Bool = { true }) -> ServiceLink {
        ServiceLink(socketPath: { self.harness.socketPath }, spawner: spawn,
                    timing: ServiceLink.Timing(retryInterval: 0.02, spawnWindow: 1,
                                               reconnectPause: 0.1, welcomeTimeout: 2,
                                               shutdownWait: 2, writeTimeout: 1,
                                               shutdownPoll: 0.02))
    }

    private func holdInstanceLock() {
        foreignLock = QxInstanceLock.acquire(at: QxInstanceLock.defaultURL)
        XCTAssertNotNil(foreignLock)
    }

    func testBluetoothThroughTheServiceWorksWhileAnotherProcessHoldsTheInstanceLock() async {
        harness.start()
        harness.transport.bringUp()
        holdInstanceLock()
        let link = serviceLink()
        XCTAssertFalse(link.needsInstanceLock)
        let exit = await QudelixCLI.run(arguments: ["--timeout", "5", "--ble", "status"],
                                        makeLinks: { _ in [link] })
        XCTAssertEqual(exit, CLIExit.ok)
        XCTAssertTrue(harness.transport.sentCommands.contains(.reqDevStatus))
        XCTAssertEqual(harness.transport.stopCount, 0)
        XCTAssertNil(harness.status)
    }

    func testTheDefaultModeStillTakesTheInstanceLockForTheUsbLink() async {
        harness.start()
        harness.transport.bringUp()
        holdInstanceLock()
        let usb = FakeLink(kind: .usb)
        usb.onSend = { _, _ in }
        let link = serviceLink()
        let exit = await QudelixCLI.run(arguments: ["--timeout", "2", "status"],
                                        makeLinks: { _ in [usb, link] })
        XCTAssertEqual(exit, CLIExit.deviceBusy)
        XCTAssertFalse(usb.started)
        XCTAssertFalse(harness.transport.sentCommands.contains(.reqDevStatus))
    }

    func testTheDefaultModeReleasesTheInstanceLockWhenItIsDone() async {
        harness.start()
        harness.transport.bringUp()
        let usb = FakeLink(kind: .usb)
        usb.onSend = { _, _ in }
        let link = serviceLink()
        let exit = await QudelixCLI.run(arguments: ["--timeout", "5", "status"],
                                        makeLinks: { _ in [usb, link] })
        XCTAssertEqual(exit, CLIExit.ok)
        let free = QxInstanceLock.acquire(at: QxInstanceLock.defaultURL)
        XCTAssertNotNil(free)
        free?.release()
    }

    func testBluetoothFallsBackToTheInProcessLinkWhenNoBinaryIsFound() {
        let bluetooth = makeLinks(preferred: .bluetooth, locateBinary: { nil })
        XCTAssertEqual(bluetooth.count, 1)
        XCTAssertTrue(bluetooth[0] is BluezTransport)
        XCTAssertTrue(bluetooth[0].needsInstanceLock)
        let both = makeLinks(preferred: nil, locateBinary: { nil })
        XCTAssertEqual(both.count, 2)
        XCTAssertTrue(both[0] is HidrawTransport)
        XCTAssertTrue(both[1] is BluezTransport)
        XCTAssertTrue(both.allSatisfy { $0.needsInstanceLock })
    }

    func testBluetoothUsesTheServiceLinkWhenABinaryIsFound() {
        let bluetooth = makeLinks(preferred: .bluetooth, locateBinary: { "/opt/qudelix/qudelix" })
        XCTAssertEqual(bluetooth.count, 1)
        XCTAssertTrue(bluetooth[0] is ServiceLink)
        XCTAssertFalse(bluetooth[0].needsInstanceLock)
        let both = makeLinks(preferred: nil, locateBinary: { "/opt/qudelix/qudelix" })
        XCTAssertEqual(both.count, 2)
        XCTAssertTrue(both[0] is HidrawTransport)
        XCTAssertTrue(both[1] is ServiceLink)
        XCTAssertEqual(makeLinks(preferred: .usb, locateBinary: { nil }).count, 1)
        XCTAssertTrue(makeLinks(preferred: .usb, locateBinary: { nil })[0] is HidrawTransport)
    }

    func testProbeSaysNotRunningWhenThereIsNoSocketAndNeverSpawns() {
        let missing = harness.directory.appendingPathComponent("absent.sock").path
        XCTAssertEqual(LinkServiceQuery.query(socketPath: missing), .notRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
    }

    func testProbeSaysWhetherTheServiceHoldsTheLink() {
        harness.start()
        XCTAssertEqual(LinkServiceQuery.query(socketPath: harness.socketPath),
                       .running(holdsLink: false))
        harness.transport.bringUp()
        XCTAssertTrue(awaitCondition {
            LinkServiceQuery.query(socketPath: harness.socketPath) == .running(holdsLink: true)
        })
        XCTAssertEqual(harness.transport.stopCount, 0)
    }

    func testProbeReportsAReplacedBuildAndReplacesNothing() {
        harness.start()
        harness.transport.bringUp()
        XCTAssertTrue(awaitCondition {
            LinkServiceQuery.query(socketPath: harness.socketPath,
                                   peerExecutable: { _ in "/usr/bin/qudelix (deleted)" })
                == .replaced(holdsLink: true)
        })
        XCTAssertEqual(LinkServiceQuery.query(socketPath: harness.socketPath,
                                              peerExecutable: { _ in nil }),
                       .running(holdsLink: true))
        XCTAssertNil(harness.status)
        XCTAssertEqual(harness.transport.stopCount, 0)
    }

    func testProbeLinesAndJsonCarryTheLinkServiceState() {
        func report(_ state: LinkServiceProbe?) -> ProbeReport {
            var report = ProbeReport(kernelRelease: "6.8", hidrawClassExists: true, nodes: [],
                                     bluetoothctlVersion: nil, busctlPresent: false,
                                     bluezOnDBus: nil, logPath: "/tmp/qudelix.log")
            report.linkService = state
            return report
        }
        XCTAssertFalse(Probe.lines(report(nil)).contains { $0.hasPrefix("link service") })
        XCTAssertTrue(Probe.lines(report(.notRunning)).contains("link service  not running"))
        XCTAssertTrue(Probe.lines(report(.running(holdsLink: true)))
            .contains("link service  running, holds the 5K's Bluetooth control link"))
        XCTAssertTrue(Probe.lines(report(.running(holdsLink: false)))
            .contains("link service  running, waiting for the 5K's Bluetooth control link"))
        XCTAssertTrue(Probe.lines(report(.replaced(holdsLink: true)))
            .contains("link service  running a replaced build; quit and reopen the app to restart it"))
        let replaced = Probe.object(report(.replaced(holdsLink: true)))["link_service"] as? [String: Bool]
        XCTAssertEqual(replaced, ["running": true, "holds_link": true, "replaced_build": true])
        let object = Probe.object(report(.running(holdsLink: true)))["link_service"] as? [String: Bool]
        XCTAssertEqual(object, ["running": true, "holds_link": true])
        XCTAssertNil(Probe.object(report(nil))["link_service"])
    }
}
#endif
