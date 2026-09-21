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
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testIgnoresOtherReportTypesAndControlCharacters() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ips = dir.appendingPathComponent("sample.ips")
        try "{\"app_name\":\"Bad\\u001bName\",\"timestamp\":\"2026-09-18 12:32:12.00 +0200\",\"bug_type\":\"298\"}\n{}".write(to: ips, atomically: true, encoding: .utf8)
        XCTAssertNil(try HistoryReader.parseIPS(ips))
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
    }
}
