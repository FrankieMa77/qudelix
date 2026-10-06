import XCTest
@testable import QudelixBar

final class BatteryHistoryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 8 * 86_400).rounded())
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }

    private func history(_ readings: [(Double, Int?, Bool)]) -> BatteryHistory {
        var h = BatteryHistory()
        for (minute, percent, charging) in readings {
            if let percent {
                h.record(percent: percent, charging: charging, at: at(minute))
            } else {
                h.recordGap(at: at(minute))
            }
        }
        return h
    }

    func testAnUnchangedReadingInsideTheHeartbeatIsNotRecorded() {
        var h = BatteryHistory()
        XCTAssertTrue(h.record(percent: 80, charging: false, at: at(0)))
        XCTAssertFalse(h.record(percent: 80, charging: false, at: at(1)))
        XCTAssertFalse(h.record(percent: 80, charging: false, at: at(9.9)))
        XCTAssertEqual(h.samples.count, 1)
    }

    func testAChangedLevelOrChargeStateIsRecordedAtOnce() {
        var h = BatteryHistory()
        h.record(percent: 80, charging: false, at: at(0))
        XCTAssertTrue(h.record(percent: 79, charging: false, at: at(1)))
        XCTAssertTrue(h.record(percent: 79, charging: true, at: at(2)))
        XCTAssertEqual(h.samples.map { $0.percent }, [80, 79, 79])
        XCTAssertEqual(h.samples.map(\.charging), [false, false, true])
    }

    func testTheHeartbeatKeepsAFlatStretchOnTheGraph() {
        var h = BatteryHistory()
        h.record(percent: 80, charging: false, at: at(0))
        XCTAssertTrue(h.record(percent: 80, charging: false, at: at(10)))
        XCTAssertEqual(h.samples.count, 2)
    }

    func testOutOfRangeLevelsAreClamped() {
        var h = BatteryHistory()
        h.record(percent: 140, charging: false, at: at(0))
        h.record(percent: -3, charging: false, at: at(1))
        XCTAssertEqual(h.samples.map { $0.percent }, [100, 0])
    }

    func testAGapIsRecordedOnceAndNeverOnAnEmptyHistory() {
        var h = BatteryHistory()
        XCTAssertFalse(h.recordGap(at: at(0)))
        h.record(percent: 50, charging: false, at: at(1))
        XCTAssertTrue(h.recordGap(at: at(2)))
        XCTAssertFalse(h.recordGap(at: at(3)))
        XCTAssertEqual(h.samples.count, 2)
        XCTAssertTrue(h.samples[1].isGap)
    }

    func testTheFirstReadingAfterALongGapIsAlwaysRecorded() {
        var h = history([(0, 50, false), (1, nil, false)])
        XCTAssertTrue(h.record(percent: 50, charging: false, at: at(7)))
        XCTAssertEqual(h.readingCount, 2)
        XCTAssertTrue(h.samples[1].isGap)
    }

    func testAShortGapWithTheSameLevelIsHealedAwayRatherThanBreakingTheLine() {
        var h = history([(0, 50, false), (1, nil, false)])
        XCTAssertTrue(h.record(percent: 50, charging: false, at: at(3)))
        XCTAssertEqual(h.samples.count, 1)
        XCTAssertFalse(h.samples[0].isGap)
    }

    func testAShortGapWithALevelOneAwayIsHealedToo() {
        var h = history([(0, 50, false), (1, nil, false)])
        XCTAssertTrue(h.record(percent: 49, charging: false, at: at(3)))
        XCTAssertEqual(h.samples.map { $0.percent }, [50, 49])
    }

    func testAShortGapAcrossAChargeChangeOrABiggerStepIsKept() {
        var charged = history([(0, 50, false), (1, nil, false)])
        charged.record(percent: 50, charging: true, at: at(3))
        XCTAssertEqual(charged.samples.count, 3)
        var dropped = history([(0, 50, false), (1, nil, false)])
        dropped.record(percent: 47, charging: false, at: at(3))
        XCTAssertEqual(dropped.samples.count, 3)
    }

    func testAFlickeringReadingLeavesNoTraceOnceItSettles() {
        var h = BatteryHistory()
        let levels = [75, 76, 75, 76, 75, 76, 75]
        for (i, level) in levels.enumerated() {
            h.record(percent: level, charging: false, at: at(Double(i) / 12))
        }
        XCTAssertEqual(h.samples.map { $0.percent }, [75])
    }

    func testAFlickerThatHasLastedAWhileIsARealChange() {
        var h = BatteryHistory()
        h.record(percent: 75, charging: false, at: at(0))
        h.record(percent: 76, charging: false, at: at(1))
        h.record(percent: 75, charging: false, at: at(1 + BatteryHistory.heartbeat / 60))
        XCTAssertEqual(h.samples.map { $0.percent }, [75, 76, 75])
    }

    func testARealDescentThroughNoiseKeepsItsShape() {
        var h = BatteryHistory()
        let levels = [76, 75, 76, 75, 74, 75, 74, 73, 74, 73, 72]
        for (i, level) in levels.enumerated() {
            h.record(percent: level, charging: false, at: at(Double(i) / 12))
        }
        XCTAssertEqual(h.samples.map { $0.percent }, [76, 75, 74, 73, 72])
    }

    func testABiggerSwingIsNotMistakenForFlicker() {
        var h = BatteryHistory()
        for (i, level) in [75, 72, 75].enumerated() {
            h.record(percent: level, charging: false, at: at(Double(i)))
        }
        XCTAssertEqual(h.samples.map { $0.percent }, [75, 72, 75])
    }

    func testChargeStateChangesAreNeverTreatedAsFlicker() {
        var h = BatteryHistory()
        h.record(percent: 75, charging: false, at: at(0))
        h.record(percent: 76, charging: true, at: at(1))
        h.record(percent: 75, charging: false, at: at(2))
        XCTAssertEqual(h.samples.map(\.charging), [false, true, false])
    }

    func testPruningKeepsOneReadingOlderThanTheRetentionWindow() {
        var h = BatteryHistory()
        let week = BatteryHistory.retention / 60
        h.record(percent: 90, charging: false, at: at(-week - 120))
        h.record(percent: 89, charging: false, at: at(-week - 60))
        h.record(percent: 88, charging: false, at: at(-30))
        h.record(percent: 87, charging: false, at: at(0))
        XCTAssertEqual(h.samples.map { $0.percent }, [89, 88, 87])
    }

    func testTheSampleCountIsCapped() {
        var h = BatteryHistory()
        for i in 0..<(BatteryHistory.maxSamples + 50) {
            h.record(percent: (i * 7) % 100, charging: false, at: at(Double(i) / 60))
        }
        XCTAssertEqual(h.samples.count, BatteryHistory.maxSamples)
    }

    func testTheCapHoldsAtLeastAWeekAtTheMeasuredRate() {
        let measuredPerDay = 1_011
        XCTAssertGreaterThanOrEqual(BatteryHistory.maxSamples, 7 * measuredPerDay)
    }

    func testOldSamplesAreThinnedSoAJitteryWeekStillFits() {
        var h = BatteryHistory()
        let step = 20.0
        let total = 3 * 24 * 3600 / Int(step)
        for i in 0..<total {
            h.record(percent: (i * 7) % 100, charging: false,
                     at: t0.addingTimeInterval(Double(i) * step))
        }
        let end = t0.addingTimeInterval(Double(total - 1) * step)
        XCTAssertLessThan(h.samples.count, BatteryHistory.maxSamples)
        XCTAssertLessThanOrEqual(h.samples[0].time.timeIntervalSince(t0), BatteryHistory.thinStep)
        let boundary = end.addingTimeInterval(-BatteryHistory.thinAge)
        let old = h.samples.filter { $0.time < boundary }
        for (a, b) in zip(old, old.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.time.timeIntervalSince(a.time),
                                        BatteryHistory.thinStep - 0.001)
        }
        let recent = h.samples.filter { $0.time >= boundary }
        XCTAssertEqual(Double(recent.count), BatteryHistory.thinAge / step, accuracy: 2)
    }

    func testThinningKeepsGapsAndChargeChanges() {
        var h = BatteryHistory()
        for i in 0..<30 {
            h.samples.append(BatterySample(time: t0.addingTimeInterval(Double(i) * 30),
                                           percent: 90, charging: i >= 20))
        }
        h.samples.insert(BatterySample(time: t0.addingTimeInterval(100), percent: nil,
                                       charging: false), at: 4)
        h.prune(now: t0.addingTimeInterval(3 * 24 * 3600))
        XCTAssertTrue(h.samples.contains { $0.isGap })
        XCTAssertTrue(h.samples.contains { $0.charging })
        XCTAssertEqual(h.samples.first?.time, t0)
        XCTAssertLessThan(h.samples.count, 31)
    }

    func testTheDrainRateNeedsHalfAnHourAndTwoLevels() {
        let short = history([(0, 80, false), (20, 79, false)])
        XCTAssertNil(short.drain(now: at(20)))
        let flat = history([(0, 80, false), (10, 80, false), (40, 80, false)])
        XCTAssertNil(flat.drain(now: at(40)))
    }

    func testTheDrainRateComesFromTheWholeDischargeRun() {
        let h = history([(0, 100, false), (60, 98, false), (120, 96, false),
                         (180, 94, false), (240, 92, false), (300, 90, false)])
        let drain = h.drain(now: at(300))
        XCTAssertEqual(drain?.percentPerHour ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(drain?.hoursLeft ?? 0, 45, accuracy: 0.01)
    }

    func testTheDrainRunStartsWhereChargingStopped() {
        let h = history([(0, 40, true), (60, 70, true), (120, 100, true),
                         (180, 100, false), (240, 97, false), (300, 94, false)])
        XCTAssertEqual(h.onBatterySince, at(180))
        XCTAssertFalse(h.runStartsAtHistoryStart)
        XCTAssertEqual(h.drain(now: at(300))?.percentPerHour ?? 0, 3, accuracy: 0.001)
    }

    func testAShortGapDoesNotEndTheDischargeRun() {
        let h = BatteryHistory(samples: [
            BatterySample(time: at(0), percent: 100, charging: false),
            BatterySample(time: at(60), percent: 97, charging: false),
            BatterySample(time: at(61), percent: nil, charging: false),
            BatterySample(time: at(63), percent: 95, charging: false),
            BatterySample(time: at(120), percent: 91, charging: false),
        ])
        XCTAssertEqual(h.onBatterySince, at(0))
        XCTAssertNotNil(h.drain(now: at(120)))
        XCTAssertTrue(h.runStartsAtHistoryStart)
    }

    func testALongGapStillEndsTheRun() {
        let h = BatteryHistory(samples: [
            BatterySample(time: at(0), percent: 100, charging: false),
            BatterySample(time: at(60), percent: 97, charging: false),
            BatterySample(time: at(61), percent: nil, charging: false),
            BatterySample(time: at(70), percent: 96, charging: false),
            BatterySample(time: at(130), percent: 92, charging: false),
        ])
        XCTAssertEqual(h.onBatterySince, at(70))
    }

    func testAGapWithTheLevelRisingDoesNotJoinTheRuns() {
        let h = BatteryHistory(samples: [
            BatterySample(time: at(0), percent: 50, charging: false),
            BatterySample(time: at(1), percent: nil, charging: false),
            BatterySample(time: at(3), percent: 60, charging: false),
            BatterySample(time: at(70), percent: 58, charging: false),
        ])
        XCTAssertEqual(h.onBatterySince, at(3))
    }

    func testAGapAcrossAChargeStateChangeDoesNotJoinTheRuns() {
        let h = BatteryHistory(samples: [
            BatterySample(time: at(0), percent: 50, charging: true),
            BatterySample(time: at(1), percent: nil, charging: false),
            BatterySample(time: at(3), percent: 49, charging: false),
            BatterySample(time: at(70), percent: 46, charging: false),
        ])
        XCTAssertEqual(h.onBatterySince, at(3))
    }

    func testSeveralBlipsInARowAllBridge() {
        let h = BatteryHistory(samples: [
            BatterySample(time: at(0), percent: 90, charging: false),
            BatterySample(time: at(10), percent: nil, charging: false),
            BatterySample(time: at(12), percent: 87, charging: false),
            BatterySample(time: at(25), percent: nil, charging: false),
            BatterySample(time: at(27), percent: 84, charging: false),
            BatterySample(time: at(40), percent: nil, charging: false),
            BatterySample(time: at(42), percent: 81, charging: false),
            BatterySample(time: at(60), percent: 77, charging: false),
        ])
        XCTAssertEqual(h.onBatterySince, at(0))
        XCTAssertNotNil(h.drain(now: at(60)))
    }

    func testNoDrainWhileChargingOrAfterAGap() {
        let charging = history([(0, 50, false), (60, 45, false), (61, 45, true)])
        XCTAssertNil(charging.drain(now: at(61)))
        XCTAssertNil(charging.onBatterySince)
        let away = history([(0, 50, false), (60, 45, false), (61, nil, false)])
        XCTAssertNil(away.drain(now: at(61)))
        XCTAssertTrue(away.currentRun.isEmpty)
    }

    func testARunFromTheStartOfHistoryIsMarked() {
        let h = history([(0, 50, false), (60, 45, false)])
        XCTAssertEqual(h.onBatterySince, at(0))
        XCTAssertTrue(h.runStartsAtHistoryStart)
    }

    func testThePlotBreaksAtAGapAndHoldsTheLastLevelToNow() {
        let h = history([(0, 80, false), (180, 70, false), (200, nil, false),
                         (240, 60, false), (300, 58, false)])
        let plot = h.plot(window: .sixHours, now: at(360))
        XCTAssertEqual(plot.lines.count, 2)
        XCTAssertEqual(plot.lines[0], [.init(x: 0, y: 80), .init(x: 0.5, y: 70)])
        XCTAssertEqual(plot.lines[1].count, 3)
        XCTAssertEqual(plot.lines[1][0].x, 240.0 / 360, accuracy: 1e-9)
        XCTAssertEqual(plot.lines[1][0].y, 60)
        XCTAssertEqual(plot.lines[1][2], .init(x: 1, y: 58))
        XCTAssertEqual(plot.latest, .init(x: 1, y: 58))
        XCTAssertTrue(plot.chargingSpans.isEmpty)
    }

    func testThePlotEntersTheWindowByInterpolation() {
        let h = history([(-60, 100, false), (60, 40, false)])
        let plot = h.plot(window: .sixHours, now: at(360))
        XCTAssertEqual(plot.lines.count, 1)
        XCTAssertEqual(plot.lines[0][0], .init(x: 0, y: 70))
        XCTAssertEqual(plot.lines[0][1].x, 60.0 / 360, accuracy: 1e-9)
        XCTAssertEqual(plot.lines[0][1].y, 40)
        XCTAssertEqual(plot.lines[0][2], .init(x: 1, y: 40))
    }

    func testReadingsEntirelyBeforeTheWindowAreDropped() {
        let h = history([(-600, 100, false), (-500, 90, false), (-400, nil, false)])
        let plot = h.plot(window: .sixHours, now: at(0))
        XCTAssertTrue(plot.isEmpty)
        XCTAssertNil(plot.latest)
    }

    func testAnOldReadingStillHoldsAcrossTheWholeWindow() {
        let h = history([(-600, 64, false)])
        let plot = h.plot(window: .sixHours, now: at(0))
        XCTAssertEqual(plot.lines, [[.init(x: 0, y: 64), .init(x: 1, y: 64)]])
    }

    func testChargingSpansAreMergedAndClipped() {
        let h = history([(-60, 50, true), (60, 60, true), (120, 70, false), (300, 68, false)])
        let plot = h.plot(window: .sixHours, now: at(360))
        XCTAssertEqual(plot.chargingSpans.count, 1)
        XCTAssertEqual(plot.chargingSpans[0].lowerBound, 0, accuracy: 1e-9)
        XCTAssertEqual(plot.chargingSpans[0].upperBound, 120.0 / 360, accuracy: 1e-9)
        XCTAssertEqual(plot.lines.count, 1)
    }

    func testSixHourTicksFallOnTheHour() {
        let calendar = utc
        let now = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 8))!
        let ticks = BatteryHistory.Window.sixHours.ticks(now: now, calendar: calendar)
        XCTAssertEqual(ticks.count, 6)
        XCTAssertEqual(ticks.first, now.addingTimeInterval(-5 * 3600))
        XCTAssertEqual(ticks.last, now)
        XCTAssertEqual(BatteryHistory.Window.sixHours.tickLabel(ticks[0], calendar: calendar), "03:00")
    }

    func testDayTicksFallOnEveryFourthHour() {
        let calendar = utc
        let now = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 8, minute: 30))!
        let ticks = BatteryHistory.Window.day.ticks(now: now, calendar: calendar)
        XCTAssertEqual(ticks.map { calendar.component(.hour, from: $0) }, [12, 16, 20, 0, 4, 8])
    }

    private func berlin(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0)
        -> (Date, Calendar) {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        c.locale = Locale(identifier: "en_GB")
        return (c.date(from: DateComponents(year: year, month: month, day: day,
                                            hour: hour, minute: minute))!, c)
    }

    func testDayTicksStayOnTheFourHourGridAcrossTheAutumnClockChange() {
        let (now, calendar) = berlin(2026, 10, 25, 13, 30)
        let ticks = BatteryHistory.Window.day.ticks(now: now, calendar: calendar)
        XCTAssertEqual(ticks.map { calendar.component(.hour, from: $0) }, [16, 20, 0, 4, 8, 12])
        XCTAssertEqual(ticks.map { calendar.component(.minute, from: $0) }, [0, 0, 0, 0, 0, 0])
        XCTAssertEqual(ticks.sorted(), ticks)
    }

    func testDayTicksStayOnTheFourHourGridAcrossTheSpringClockChange() {
        let (now, calendar) = berlin(2027, 3, 28, 13, 30)
        let ticks = BatteryHistory.Window.day.ticks(now: now, calendar: calendar)
        XCTAssertEqual(ticks.map { calendar.component(.hour, from: $0) }, [16, 20, 0, 4, 8, 12])
    }

    func testSixHourTicksSurviveTheClockChange() {
        let (now, calendar) = berlin(2026, 10, 25, 4, 30)
        let ticks = BatteryHistory.Window.sixHours.ticks(now: now, calendar: calendar)
        XCTAssertEqual(Set(ticks).count, ticks.count)
        XCTAssertEqual(ticks.sorted(), ticks)
        XCTAssertTrue(ticks.allSatisfy { calendar.component(.minute, from: $0) == 0 })
    }

    func testWeekTicksStayAtMidnightAcrossTheClockChange() {
        let (now, calendar) = berlin(2026, 10, 28, 9)
        let ticks = BatteryHistory.Window.week.ticks(now: now, calendar: calendar)
        XCTAssertEqual(ticks.count, 7)
        XCTAssertTrue(ticks.allSatisfy { calendar.component(.hour, from: $0) == 0 })
    }

    func testWeekTicksFallAtMidnight() {
        let calendar = utc
        let now = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 8))!
        let ticks = BatteryHistory.Window.week.ticks(now: now, calendar: calendar)
        XCTAssertEqual(ticks.count, 7)
        XCTAssertEqual(ticks.map { calendar.component(.day, from: $0) }, [9, 10, 11, 12, 13, 14, 15])
        XCTAssertTrue(ticks.allSatisfy { calendar.component(.hour, from: $0) == 0 })
        XCTAssertEqual(BatteryHistory.Window.week.tickLabel(ticks[0], calendar: calendar), "Sat")
    }

    func testDurationsReadNaturally() {
        XCTAssertEqual(BatteryHistoryBody.duration(30), "1 min")
        XCTAssertEqual(BatteryHistoryBody.duration(25 * 60), "25 min")
        XCTAssertEqual(BatteryHistoryBody.duration(3 * 3600), "3 h")
        XCTAssertEqual(BatteryHistoryBody.duration(3 * 3600 + 12 * 60), "3 h 12 min")
        XCTAssertEqual(BatteryHistoryBody.duration(2 * 86400 + 5 * 3600), "2 d 5 h")
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("battery-history-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testTheFileRoundTrips() {
        let url = scratch.appendingPathComponent("battery-history.json")
        let h = history([(0, 80, true), (60, 90, true), (61, nil, false), (120, 88, false)])
        XCTAssertTrue(BatteryHistoryFile.save(h, to: url))
        XCTAssertEqual(BatteryHistoryFile.load(from: url), h)
    }

    func testAMissingFileIsAnEmptyHistory() {
        XCTAssertTrue(BatteryHistoryFile.load(from: scratch.appendingPathComponent("none.json")).isEmpty)
    }

    func testACorruptFileIsParkedAndReplacedByAnEmptyHistory() throws {
        let url = scratch.appendingPathComponent("battery-history.json")
        try Data("{not json".utf8).write(to: url)
        XCTAssertTrue(BatteryHistoryFile.load(from: url).isEmpty)
        let parked = scratch.appendingPathComponent("battery-history.json.recovered")
        XCTAssertEqual(try Data(contentsOf: parked), Data("{not json".utf8))
    }

    func testLevelsOutsideTheScaleAreDroppedOnLoad() throws {
        let url = scratch.appendingPathComponent("battery-history.json")
        let time = Int(t0.timeIntervalSince1970)
        let json = """
        {"samples":[{"time":\(time),"percent":250,"charging":false},\
        {"time":\(time + 60),"percent":-1,"charging":false},\
        {"time":\(time + 120),"percent":100,"charging":false},\
        {"time":\(time + 180),"percent":0,"charging":false}]}
        """
        try Data(json.utf8).write(to: url)
        XCTAssertEqual(BatteryHistoryFile.load(from: url).samples.map { $0.percent }, [100, 0])
        XCTAssertEqual(try Data(contentsOf: scratch.appendingPathComponent(
            "battery-history.json.recovered")), Data(json.utf8))
    }

    func testHostileTimesAreDroppedOnLoadAndNeverReachTheDrawer() throws {
        let url = scratch.appendingPathComponent("battery-history.json")
        let good = Int(t0.timeIntervalSince1970)
        let json = """
        {"samples":[{"time":\(good),"percent":80,"charging":false},\
        {"time":"NaN","percent":79,"charging":false},\
        {"time":"Infinity","percent":78,"charging":false},\
        {"time":"-Infinity","percent":77,"charging":false},\
        {"time":1e300,"percent":76,"charging":false},\
        {"time":-1e300,"percent":75,"charging":false},\
        {"time":180000000000000,"percent":74,"charging":false},\
        {"time":0,"percent":73,"charging":false},\
        {"time":1500000000,"percent":72,"charging":false},\
        {"time":\(good + 10 * 86400),"percent":71,"charging":false},\
        {"time":\(good + 600),"percent":"seventy","charging":false},\
        {"time":\(good + 900),"percent":1e300,"charging":false},\
        {"time":\(good + 1200),"percent":null,"charging":false}]}
        """
        try Data(json.utf8).write(to: url)

        let h = BatteryHistoryFile.load(from: url)

        XCTAssertEqual(h.samples.map { $0.percent }, [80, nil])
        XCTAssertEqual(h.samples.map { $0.time.timeIntervalSince1970 },
                       [Double(good), Double(good + 1200)])
        XCTAssertEqual(try Data(contentsOf: scratch.appendingPathComponent(
            "battery-history.json.recovered")), Data(json.utf8))
        if let since = h.onBatterySince {
            XCTAssertLessThan(Date().timeIntervalSince(since), 30 * 86_400)
        }
    }

    func testTheLoaderRejectsNonFiniteAndOutOfRangeTimesFromAnyRoute() {
        let now = t0.addingTimeInterval(3_600)
        let samples = [
            BatterySample(time: t0, percent: 50, charging: false),
            BatterySample(time: Date(timeIntervalSince1970: .nan), percent: 50, charging: false),
            BatterySample(time: Date(timeIntervalSince1970: .infinity), percent: 50, charging: false),
            BatterySample(time: Date(timeIntervalSince1970: -.infinity), percent: 50, charging: false),
            BatterySample(time: Date(timeIntervalSince1970: 1e300), percent: 50, charging: false),
            BatterySample(time: Date(timeIntervalSince1970: 1.8e14), percent: 50, charging: false),
            BatterySample(time: BatteryHistoryFile.earliestPlausible.addingTimeInterval(-1),
                          percent: 50, charging: false),
            BatterySample(time: now.addingTimeInterval(BatteryHistoryFile.futureTolerance + 1),
                          percent: 50, charging: false),
            BatterySample(time: now.addingTimeInterval(BatteryHistoryFile.futureTolerance - 1),
                          percent: 40, charging: false),
            BatterySample(time: t0.addingTimeInterval(10), percent: 101, charging: false),
            BatterySample(time: t0.addingTimeInterval(20), percent: nil, charging: false),
        ]
        let kept = BatteryHistoryFile.plausible(samples, now: now)
        XCTAssertEqual(kept.map { $0.percent }, [50, 40, nil])
    }

    func testTwoDifferentDamagedFilesKeepTwoCopies() throws {
        let url = scratch.appendingPathComponent("battery-history.json")
        let candidates = ParkedCopy.candidates(beside: url)
        try Data("{not json".utf8).write(to: url)
        XCTAssertTrue(BatteryHistoryFile.load(from: url).isEmpty)
        try Data("{still not json".utf8).write(to: url)
        XCTAssertTrue(BatteryHistoryFile.load(from: url).isEmpty)
        XCTAssertEqual(try String(contentsOf: candidates[0], encoding: .utf8), "{not json")
        XCTAssertEqual(try String(contentsOf: candidates[1], encoding: .utf8), "{still not json")
    }

    func testAnUntouchedFileIsNeverParkedOnLoad() throws {
        let url = scratch.appendingPathComponent("battery-history.json")
        let h = history([(0, 80, false), (60, 79, false), (61, nil, false), (300, 70, false)])
        XCTAssertTrue(BatteryHistoryFile.save(h, to: url))
        XCTAssertEqual(BatteryHistoryFile.load(from: url), h)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: scratch.appendingPathComponent("battery-history.json.recovered").path))
    }

    @MainActor
    func testTheLogPersistsWhatItRecordsAndReloadsIt() {
        let url = scratch.appendingPathComponent("battery-history.json")
        let log = BatteryLog(fileURL: url)
        log.record(percent: 77, charging: false, at: at(0))
        log.recordGap(at: at(5))
        log.saveNow()
        let reloaded = BatteryLog(fileURL: url)
        XCTAssertEqual(reloaded.history, log.history)
        XCTAssertEqual(reloaded.history.samples.count, 2)
    }

    func testAnOldFileLoadsUnchanged() throws {
        let url = scratch.appendingPathComponent("battery-history.json")
        let json = """
        {"samples":[{"charging":false,"percent":80,"time":1800000000.5},\
        {"charging":false,"time":1800000600},\
        {"charging":true,"percent":79,"time":1800000900.123456}]}
        """
        try Data(json.utf8).write(to: url)
        let then = Date(timeIntervalSince1970: 1_800_100_000)
        let h = BatteryHistoryFile.load(from: url, now: then)
        XCTAssertEqual(h.samples.count, 3)
        XCTAssertEqual(h.samples.map { $0.percent }, [80, nil, 79])
        XCTAssertEqual(h.samples.map(\.charging), [false, false, true])
        XCTAssertEqual(h.samples[0].time.timeIntervalSince1970, 1_800_000_000.5, accuracy: 1e-6)
        XCTAssertEqual(h.samples[2].time.timeIntervalSince1970, 1_800_000_900.123456, accuracy: 1e-6)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".recovered"))
        XCTAssertEqual(BatteryHistoryFile.load(from: url, now: then), h)
    }

    @MainActor
    func testAnInMemoryLogWritesNothing() {
        let log = BatteryLog.inMemory()
        log.record(percent: 77, charging: false, at: at(0))
        log.saveNow()
        XCTAssertEqual(log.history.readingCount, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
    }

    @MainActor
    private final class VirtualClock {
        var now: Date
        var queue: [(Date, DispatchWorkItem)] = []

        init(_ start: Date) { now = start }

        func attach(to log: BatteryLog) {
            log.schedule = { [unowned self] delay, work in
                queue.append((now.addingTimeInterval(delay), work))
            }
        }

        func advance(to time: Date) {
            while let first = queue.first, first.0 <= time {
                queue.removeFirst()
                now = first.0
                first.1.perform()
            }
            now = time
        }
    }

    @MainActor
    func testSavesRideOneTimerInsteadOfFollowingEveryChange() {
        let url = scratch.appendingPathComponent("battery-history.json")
        let log = BatteryLog(fileURL: url)
        let clock = VirtualClock(t0)
        clock.attach(to: log)
        for i in 0..<20 {
            clock.advance(to: t0.addingTimeInterval(Double(i) * 10))
            log.record(percent: 90 - i * 2, charging: false, at: clock.now)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(clock.queue.count, 1)
        clock.advance(to: t0.addingTimeInterval(BatteryLog.saveDelay + 1))
        XCTAssertEqual(log.saveCount, 1)
        XCTAssertEqual(BatteryHistoryFile.load(from: url).readingCount, 20)
        XCTAssertTrue(clock.queue.isEmpty)
        log.record(percent: 40, charging: false, at: clock.now)
        XCTAssertEqual(clock.queue.count, 1)
    }

    @MainActor
    func testAnUnchangedLogWritesNothingWhenFlushed() {
        let url = scratch.appendingPathComponent("battery-history.json")
        let log = BatteryLog(fileURL: url)
        log.saveNow()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(log.saveCount, 0)
    }

    @MainActor
    func testQuittingFlushesTheLastReadingsAndMarksTheClose() {
        let url = scratch.appendingPathComponent("battery-history.json")
        let log = BatteryLog(fileURL: url)
        let clock = VirtualClock(t0)
        clock.attach(to: log)
        log.record(percent: 60, charging: true, at: at(0))
        log.record(percent: 62, charging: true, at: at(30))
        log.appWillTerminate(at: at(31))
        XCTAssertEqual(log.saveCount, 1)
        let reloaded = BatteryHistoryFile.load(from: url)
        XCTAssertEqual(reloaded.samples.map { $0.percent }, [60, 62, nil])
        XCTAssertEqual(reloaded.samples.last?.time, at(31))
        XCTAssertTrue(clock.queue.allSatisfy { $0.1.isCancelled })
        log.appWillTerminate(at: at(32))
        XCTAssertEqual(BatteryHistoryFile.load(from: url).samples.count, 3)
    }

    @MainActor
    func testAClosedGapStopsTheChargingShadingAtTheMomentOfQuitting() {
        let log = BatteryLog.inMemory()
        log.record(percent: 90, charging: true, at: at(0))
        log.appWillTerminate(at: at(10))
        log.record(percent: 85, charging: false, at: at(300))
        let plot = log.history.plot(window: .sixHours, now: at(305))
        XCTAssertEqual(plot.chargingSpans.count, 1)
        XCTAssertEqual(plot.chargingSpans[0].lowerBound, 55.0 / 360, accuracy: 1e-9)
        XCTAssertEqual(plot.chargingSpans[0].upperBound, 65.0 / 360, accuracy: 1e-9)
    }

    @MainActor
    func testAFailedWriteKeepsTheDataAndTriesAgainOnTheNextTimer() throws {
        let folder = scratch.appendingPathComponent("not-yet")
        let url = folder.appendingPathComponent("battery-history.json")
        let log = BatteryLog(fileURL: url)
        let clock = VirtualClock(t0)
        clock.attach(to: log)
        log.record(percent: 70, charging: false, at: at(0))
        clock.advance(to: at(0).addingTimeInterval(BatteryLog.saveDelay + 1))
        XCTAssertEqual(log.saveCount, 0)
        XCTAssertEqual(clock.queue.count, 1)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        clock.advance(to: clock.now.addingTimeInterval(BatteryLog.saveDelay + 1))
        XCTAssertEqual(log.saveCount, 1)
        XCTAssertEqual(BatteryHistoryFile.load(from: url).readingCount, 1)
    }

    private struct Stream {
        var state: UInt64
        mutating func unit() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    @MainActor
    func testADayOfPlusMinusOnePercentFlickerWritesAFractionOfWhatItUsedTo() {
        let url = scratch.appendingPathComponent("battery-history.json")
        let log = BatteryLog(fileURL: url)
        let clock = VirtualClock(t0)
        clock.attach(to: log)
        var noise = Stream(state: 42)
        var legacy = BatteryHistory()
        var legacyWrites = 0
        var legacyBytes = 0
        var savesBefore = 0
        var bytesBefore = 0
        var bytesPerSample = 0
        let warmDays = 6
        let pushesPerDay = 24 * 3600 / 5
        for i in 0..<(pushesPerDay * (warmDays + 1)) {
            let measuring = i >= pushesPerDay * warmDays
            if i == pushesPerDay * warmDays {
                savesBefore = log.saveCount
                bytesBefore = log.bytesWritten
                let encoded = BatteryHistoryFile.encoded(legacy)?.count ?? 0
                bytesPerSample = encoded / max(1, legacy.samples.count)
            }
            let time = t0.addingTimeInterval(Double(i) * 5)
            clock.advance(to: time)
            let hours = Double(i) * 5 / 3600
            let truth = 100 - 3.0 * hours.truncatingRemainder(dividingBy: 25)
            let level = max(0, min(100, Int((truth + (noise.unit() - 0.5) * 0.16).rounded())))
            log.record(percent: level, charging: false, at: time)
            let last = legacy.samples.last
            if last == nil || last?.percent != level
                || time.timeIntervalSince(last!.time) >= BatteryHistory.heartbeat {
                legacy.samples.append(BatterySample(time: time, percent: level, charging: false))
                if legacy.samples.count > 6000 { legacy.samples.removeFirst() }
                if measuring {
                    legacyWrites += 1
                    legacyBytes += legacy.samples.count * bytesPerSample
                }
            }
        }
        log.appWillTerminate(at: t0.addingTimeInterval(Double(pushesPerDay * (warmDays + 1)) * 5))
        let saves = log.saveCount - savesBefore
        let bytes = log.bytesWritten - bytesBefore
        XCTAssertGreaterThan(legacyWrites, 850, "the model should reproduce the measured rate")
        XCTAssertLessThan(legacyWrites, 1_300)
        XCTAssertLessThanOrEqual(saves, 24 * 3600 / Int(BatteryLog.saveDelay) + 1)
        XCTAssertLessThan(saves * 3, legacyWrites)
        XCTAssertLessThan(bytes * 10, legacyBytes)
        let loaded = BatteryHistoryFile.load(from: url)
        XCTAssertEqual(loaded.samples.count, log.history.samples.count)
        XCTAssertLessThan(log.history.samples.count * 2, legacy.samples.count)
    }
}
