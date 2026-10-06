import XCTest
@testable import QudelixBar

@MainActor
final class CatalogueRefreshTests: XCTestCase {
    private func waitForTask(_ service: AutoEqService) async {
        await service.loadTask?.value
    }

    private func entries(_ names: [String]) -> Data {
        catalogueJSON(Dictionary(uniqueKeysWithValues: names.map {
            ($0, [["form": "over-ear", "rig": "GRAS 45BC-10", "source": "oratory1990"]])
        }))
    }

    func testAFreshCatalogueIsNotFetchedAgain() async {
        let transport = PathTransport()
        transport.set("/entries", .success(entries(["Alpha One"])))
        transport.set("/targets", .success(catalogueJSON([])))
        let service = AutoEqService(transport: transport)
        service.prepare()
        await waitForTask(service)
        service.prepare()
        service.prepare()
        await waitForTask(service)
        XCTAssertEqual(transport.count("/entries"), 1)
        XCTAssertEqual(service.models.count, 1)
    }

    func testAStaleCatalogueRefreshesInTheBackgroundWithoutFlickering() async {
        let transport = PathTransport()
        transport.set("/entries", .success(entries(["Alpha One"])))
        transport.set("/targets", .success(catalogueJSON([])))
        let service = AutoEqService(transport: transport)
        service.maxAge = 0
        service.prepare()
        await waitForTask(service)
        XCTAssertEqual(service.state, .ready)

        transport.set("/entries", .success(entries(["Alpha One", "Beta Two"])))
        service.prepare()
        XCTAssertEqual(service.state, .ready, "a refresh must not blank the list")
        XCTAssertEqual(service.models.count, 1)
        await waitForTask(service)
        XCTAssertEqual(service.models.count, 2)
        XCTAssertEqual(service.state, .ready)
        XCTAssertEqual(transport.count("/entries"), 2)
    }

    func testAFailedRefreshKeepsTheOldCatalogueAndBacksOff() async {
        let transport = PathTransport()
        transport.set("/entries", .success(entries(["Alpha One"])))
        transport.set("/targets", .success(catalogueJSON([])))
        let service = AutoEqService(transport: transport)
        service.maxAge = 0
        service.retryAfter = 3600
        service.prepare()
        await waitForTask(service)

        transport.set("/entries", .failure(URLError(.notConnectedToInternet)))
        service.prepare()
        await waitForTask(service)
        XCTAssertEqual(service.state, .ready)
        XCTAssertEqual(service.models.count, 1)
        XCTAssertEqual(transport.count("/entries"), 2)

        service.prepare()
        service.prepare()
        await waitForTask(service)
        XCTAssertEqual(transport.count("/entries"), 2, "backing off, not hammering")
    }

    func testAFailedFirstLoadStillRetriesOnTheNextVisit() async {
        let transport = PathTransport()
        transport.set("/entries", .failure(URLError(.notConnectedToInternet)))
        transport.set("/targets", .failure(URLError(.notConnectedToInternet)))
        let service = AutoEqService(transport: transport)
        service.prepare()
        await waitForTask(service)
        guard case .failed = service.state else { return XCTFail("expected a failure") }

        transport.set("/entries", .success(entries(["Alpha One"])))
        transport.set("/targets", .success(catalogueJSON([])))
        service.prepare()
        await waitForTask(service)
        XCTAssertEqual(service.state, .ready)
        XCTAssertEqual(service.models.count, 1)
    }

    func testOneSharedServiceAndOneSharedIndexServeEveryScreen() {
        XCTAssertTrue(AutoEqService.shared === AutoEqService.shared)
        XCTAssertTrue(AutoEqIndex.shared === AutoEqIndex.shared)
    }

    private let indexText = """
        - [Sennheiser HD 600](./oratory1990/over-ear/Sennheiser%20HD%20600)
        - [Sennheiser HD 600 (2020)](./crinacle/over-ear/Sennheiser%20HD%20600%20(2020))
        """

    func testAnIndexIsFetchedOnceAndKeptWhileItIsFresh() async {
        let calls = CallCounter()
        let text = indexText
        let index = AutoEqIndex(fetcher: { _, _ in calls.bump(); return Data(text.utf8) })
        index.loadIfNeeded()
        await index.loadTask?.value
        index.loadIfNeeded()
        index.loadIfNeeded()
        await index.loadTask?.value
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(index.entries.count, 2)
        XCTAssertEqual(index.state, .ready)
    }

    func testAStaleIndexRefreshesQuietlyAndKeepsItsEntriesOnFailure() async {
        let calls = CallCounter()
        let text = indexText
        let offline = Flag()
        let index = AutoEqIndex(fetcher: { _, _ in
            calls.bump()
            if offline.isOn { throw URLError(.notConnectedToInternet) }
            return Data(text.utf8)
        })
        index.maxAge = 0
        index.retryAfter = 3600
        index.loadIfNeeded()
        await index.loadTask?.value
        XCTAssertEqual(index.state, .ready)

        offline.set(true)
        index.loadIfNeeded()
        XCTAssertEqual(index.state, .ready, "a refresh must not blank the list")
        await index.loadTask?.value
        XCTAssertEqual(index.state, .ready)
        XCTAssertEqual(index.entries.count, 2)
        XCTAssertEqual(calls.value, 2)

        index.loadIfNeeded()
        await index.loadTask?.value
        XCTAssertEqual(calls.value, 2, "backing off after a failed refresh")
    }

    func testAFailedFirstIndexLoadIsRetriedNextTime() async {
        let offline = Flag()
        offline.set(true)
        let text = indexText
        let index = AutoEqIndex(fetcher: { _, _ in
            if offline.isOn { throw URLError(.notConnectedToInternet) }
            return Data(text.utf8)
        })
        index.loadIfNeeded()
        await index.loadTask?.value
        guard case .failed = index.state else { return XCTFail("expected a failure") }

        offline.set(false)
        index.loadIfNeeded()
        await index.loadTask?.value
        XCTAssertEqual(index.state, .ready)
        XCTAssertEqual(index.entries.count, 2)
    }
}
