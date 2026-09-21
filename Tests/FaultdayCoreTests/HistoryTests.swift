import XCTest
@testable import FaultdayCore

final class HistoryTests: XCTestCase {
    func testReadsCrashHeaderAndInstallHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ips = dir.appendingPathComponent("sample.ips")
        try """
        {"app_name":"Example","timestamp":"2026-09-18 12:32:12.00 +0200","bug_type":"309","incident_id":"abc","app_version":"1.0"}
        {"private":"not needed"}
        """.write(to: ips, atomically: true, encoding: .utf8)
        let plist = dir.appendingPathComponent("history.plist")
        let rows: [[String: Any]] = [["date": Date(timeIntervalSince1970: 1_700_000_000), "displayName": "Example", "displayVersion": "2.0"]]
        let bytes = try PropertyListSerialization.data(fromPropertyList: rows, format: .xml, options: 0)
        try bytes.write(to: plist)
        let result = HistoryReader.scan(reports: [dir], installHistory: plist)
        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(Set(result.events.map(\.kind)), Set([.crash, .install]))
        XCTAssertEqual(result.events.first { $0.kind == .crash }?.reportPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }, ips.standardizedFileURL.path)
        XCTAssertNil(result.events.first { $0.kind == .install }?.reportPath)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testIgnoresOtherReportTypesAndControlCharacters() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ips = dir.appendingPathComponent("sample.ips")
        try "{\"app_name\":\"Bad\\u001bName\",\"timestamp\":\"2026-09-18 12:32:12.00 +0200\",\"bug_type\":\"298\"}\n{}".write(to: ips, atomically: true, encoding: .utf8)
        XCTAssertNil(try HistoryReader.parseIPS(ips))
        let panic = dir.appendingPathComponent("Kernel_1.panic")
        try "panic".write(to: panic, atomically: true, encoding: .utf8)
        let hidden = dir.appendingPathComponent(".WindowServer.ips")
        try "{\"bug_type\":\"409\"}\n{}".write(to: hidden, atomically: true, encoding: .utf8)
        let result = HistoryReader.scan(reports: [dir], installHistory: nil)
        XCTAssertEqual(result.otherReports, 3)
        XCTAssertTrue(result.events.isEmpty)
    }


    func testRetiredReportsAndIncompleteReportWarning() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let retired = dir.appendingPathComponent("Retired")
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = retired.appendingPathComponent("old.ips")
        try "{\"app_name\":\"OldApp\",\"timestamp\":\"2025-09-18 12:32:12.00 +0200\",\"bug_type\":\"309\",\"incident_id\":\"old-1\"}\n{}".write(to: old, atomically: true, encoding: .utf8)
        try Data().write(to: dir.appendingPathComponent("incomplete.ips"))
        let result = HistoryReader.scan(reports: [dir], installHistory: nil)
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events[0].title, "OldApp")
        XCTAssertTrue(result.warnings.contains { $0.contains("Skipped 1 unreadable or incomplete crash report") })
    }
    func testFixtureSwitchDoesNotReadLiveSources() {
        let sources = HistoryReader.defaultSources(environment: ["FAULTDAY_REPORTS_DIR": "/tmp/example"])
        XCTAssertEqual(sources.reports.count, 1)
        XCTAssertNil(sources.installs)
        XCTAssertFalse(HistoryReader.shouldScanAtLaunch(arguments: ["faultday", "--help"], environment: [:]))
        XCTAssertFalse(HistoryReader.shouldScanAtLaunch(arguments: ["faultday"], environment: ["FAULTDAY_SELFTEST": "render"]))
        XCTAssertFalse(HistoryReader.shouldScanAtLaunch(arguments: ["faultday", "--demo"], environment: [:]))
        XCTAssertTrue(HistoryReader.shouldScanAtLaunch(arguments: ["faultday"], environment: [:]))
    }

    func testOversizeInstallHistoryWarnsInsteadOfSilentlyVanishing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist = dir.appendingPathComponent("large.plist")
        try Data().write(to: plist)
        let handle = try FileHandle(forWritingTo: plist)
        try handle.truncate(atOffset: 32_000_001)
        try handle.close()
        let result = HistoryReader.scan(reports: [dir], installHistory: plist)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertTrue(result.warnings.contains("Installation history is too large to read"))
    }

    func testHourlyBucketsUseLocalCalendarDayAndSeparateKinds() {
        XCTAssertEqual(HistorySeries.emptyStateMessage(kinds: []), "Enable Crashes or Installs to see events.")
        XCTAssertEqual(HistorySeries.emptyStateMessage(kinds: [.crash]), "Choose another day or clear the hour filter.")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 2 * 3600)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 9, day: 18))!
        let crash = HistoryEvent(id: "a", date: calendar.date(byAdding: .hour, value: 10, to: day)!, kind: .crash,
                                 title: "Example", detail: "", source: "")
        let install = HistoryEvent(id: "b", date: calendar.date(byAdding: .hour, value: 10, to: day)!, kind: .install,
                                   title: "Example", detail: "", source: "")
        let nextDay = HistoryEvent(id: "c", date: calendar.date(byAdding: .day, value: 1, to: day)!, kind: .crash,
                                   title: "Example", detail: "", source: "")
        let buckets = HistorySeries.hourly([crash, install, nextDay], on: day, calendar: calendar)
        XCTAssertEqual(buckets.count, 24)
        XCTAssertEqual(buckets[10], HourlyCount(hour: 10, crashes: 1, installs: 1))
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.total }, 2)
        XCTAssertEqual(HistorySeries.matching([crash, install, nextDay], kinds: [.crash], day: day, hour: 10, calendar: calendar).map(\.id), ["a"])
        XCTAssertTrue(HistorySeries.matching([crash, install, nextDay], kinds: [.install], day: day, hour: 11, calendar: calendar).isEmpty)
    }


}
