import Foundation

public enum EventKind: String, CaseIterable, Codable {
    case crash = "Crash"
    case install = "Install"
}

public struct HistoryEvent: Identifiable, Equatable {
    public let id: String
    public let date: Date
    public let kind: EventKind
    public let title: String
    public let detail: String
    public let source: String
    public let reportPath: String?

    public init(id: String, date: Date, kind: EventKind, title: String, detail: String, source: String, reportPath: String? = nil) {
        self.id = id; self.date = date; self.kind = kind; self.title = title
        self.detail = detail; self.source = source; self.reportPath = reportPath
    }
}

public struct HistoryResult {
    public let events: [HistoryEvent]
    public let warnings: [String]
    public let sources: [String]
    public let otherReports: Int

    public init(events: [HistoryEvent], warnings: [String], sources: [String], otherReports: Int = 0) {
        self.events = events
        self.warnings = warnings
        self.sources = sources
        self.otherReports = otherReports
    }
}

public struct HourlyCount: Equatable {
    public let hour: Int
    public let crashes: Int
    public let installs: Int

    public var total: Int { crashes + installs }
}

public enum HistorySeries {
    public static func emptyStateMessage(kinds: Set<EventKind>) -> String {
        kinds.isEmpty ? "Enable Crashes or Installs to see events." : "Choose another day or clear the hour filter."
    }

    public static func matching(_ events: [HistoryEvent], kinds: Set<EventKind>, day: Date?, hour: Int?, calendar: Calendar = .current) -> [HistoryEvent] {
        events.filter { event in
            guard kinds.contains(event.kind) else { return false }
            if let day, !calendar.isDate(event.date, inSameDayAs: day) { return false }
            if let hour, calendar.component(.hour, from: event.date) != hour { return false }
            return true
        }
    }

    public static func hourly(_ events: [HistoryEvent], on day: Date, calendar: Calendar = .current) -> [HourlyCount] {
        var crashes = Array(repeating: 0, count: 24)
        var installs = Array(repeating: 0, count: 24)
        for event in events where calendar.isDate(event.date, inSameDayAs: day) {
            let hour = calendar.component(.hour, from: event.date)
            guard (0..<24).contains(hour) else { continue }
            switch event.kind {
            case .crash: crashes[hour] += 1
            case .install: installs[hour] += 1
            }
        }
        return (0..<24).map { HourlyCount(hour: $0, crashes: crashes[$0], installs: installs[$0]) }
    }


}

public enum HistoryReader {
    private enum ParseError: Error { case malformed, tooLarge }

    public static func shouldScanAtLaunch(arguments: [String], environment: [String: String]) -> Bool {
        if environment["FAULTDAY_SELFTEST"] != nil { return false }
        return !arguments.dropFirst().contains { ["--help", "help", "--demo"].contains($0) }
    }

    public static func scan(reports: [URL], installHistory: URL?) -> HistoryResult {
        var events = [HistoryEvent]()
        var warnings = [String]()
        var sources = [String]()
        var seen = Set<String>()
        var malformedCount = 0
        var otherReports = 0
        var directories = [URL]()
        for root in reports {
            directories.append(root)
            let retired = root.appendingPathComponent("Retired", isDirectory: true)
            if let values = try? retired.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
               values.isDirectory == true, values.isSymbolicLink != true { directories.append(retired) }
        }
        for directory in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                warnings.append("Could not read crash reports at \(directory.path)")
                continue
            }
            sources.append(directory.path)
            for file in entries {
                guard let attrs = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), attrs.isRegularFile == true, attrs.isSymbolicLink != true else { continue }
                let ext = file.pathExtension.lowercased()
                if ext != "ips" {
                    if ["panic", "spin", "diag", "dpsub"].contains(ext) { otherReports += 1 }
                    continue
                }
                do {
                    if let event = try parseIPS(file) {
                        if seen.insert(event.id).inserted { events.append(event) }
                    } else { otherReports += 1 }
                } catch {
                    malformedCount += 1
                }
            }
        }
        if malformedCount > 0 {
            warnings.append("Skipped \(malformedCount) unreadable or incomplete crash report\(malformedCount == 1 ? "" : "s")")
        }
        if let installHistory {
            do {
                let installs = try parseInstallHistory(installHistory)
                events.append(contentsOf: installs)
                sources.append(installHistory.path)
            } catch ParseError.tooLarge {
                warnings.append("Installation history is too large to read")
            } catch {
                warnings.append("Could not read installation history")
            }
        }
        events.sort { $0.date > $1.date }
        return HistoryResult(events: events, warnings: warnings, sources: sources, otherReports: otherReports)
    }

    public static func parseIPS(_ url: URL) throws -> HistoryEvent? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 16384) ?? Data()
        guard let newline = data.firstIndex(of: 10), newline < 8192 else { throw ParseError.malformed }
        let header = Data(data[..<newline])
        guard let object = try JSONSerialization.jsonObject(with: header) as? [String: Any],
              let bugType = object["bug_type"] as? String else { throw ParseError.malformed }
        guard bugType == "309" else { return nil }
        guard let timestamp = object["timestamp"] as? String,
              let date = parseDate(timestamp) else { throw ParseError.malformed }
        let name = safeText((object["app_name"] as? String) ?? (object["name"] as? String) ?? "Unknown app")
        let id = (object["incident_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent
        let version = safeText(object["app_version"] as? String ?? "")
        return HistoryEvent(id: "crash:\(id)", date: date, kind: .crash, title: name,
                            detail: version.isEmpty ? "App crash" : "App crash · version \(version)", source: "Diagnostic report", reportPath: url.path)
    }

    public static func parseInstallHistory(_ url: URL) throws -> [HistoryEvent] {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
              let size = properties.fileSize else { throw ParseError.malformed }
        guard size <= 32_000_000 else { throw ParseError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 32_000_000 else { throw ParseError.tooLarge }
        guard let rows = try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { throw ParseError.malformed }
        return rows.enumerated().compactMap { index, row in
            guard let date = row["date"] as? Date, let name = row["displayName"] as? String else { return nil }
            let version = safeText(row["displayVersion"] as? String ?? "")
            return HistoryEvent(id: "install:\(index)", date: date, kind: .install, title: safeText(name),
                                detail: version.isEmpty ? "Software installed" : "Software installed · version \(version)",
                                source: "Installation history")
        }
    }

    public static func defaultSources(environment: [String: String] = ProcessInfo.processInfo.environment) -> (reports: [URL], installs: URL?) {
        if let fixture = environment["FAULTDAY_REPORTS_DIR"] {
            let install = environment["FAULTDAY_INSTALL_HISTORY"].map { URL(fileURLWithPath: $0) }
            return ([URL(fileURLWithPath: fixture)], install)
        }
        return ([FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
                 URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")],
                URL(fileURLWithPath: "/Library/Receipts/InstallHistory.plist"))
    }

    private static func safeText(_ raw: String) -> String {
        let stripped = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(stripped)).prefix(120).description
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for pattern in ["yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ss.SSSZ"] {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}
