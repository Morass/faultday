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

    public init(id: String, date: Date, kind: EventKind, title: String, detail: String, source: String) {
        self.id = id; self.date = date; self.kind = kind; self.title = title
        self.detail = detail; self.source = source
    }
}

public struct HistoryResult {
    public let events: [HistoryEvent]
    public let warnings: [String]
    public let sources: [String]
}

public enum HistoryReader {
    private enum ParseError: Error { case malformed }

    public static func scan(reports: [URL], installHistory: URL?) -> HistoryResult {
        var events = [HistoryEvent]()
        var warnings = [String]()
        var sources = [String]()
        var seen = Set<String>()
        var malformedCount = 0
        var directories = [URL]()
        for root in reports {
            directories.append(root)
            let retired = root.appendingPathComponent("Retired", isDirectory: true)
            if let values = try? retired.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
               values.isDirectory == true, values.isSymbolicLink != true { directories.append(retired) }
        }
        for directory in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
                warnings.append("Could not read crash reports at \(directory.path)")
                continue
            }
            sources.append(directory.path)
            for file in entries where file.pathExtension.lowercased() == "ips" {
                guard let attrs = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), attrs.isRegularFile == true, attrs.isSymbolicLink != true else { continue }
                do {
                    if let event = try parseIPS(file), seen.insert(event.id).inserted { events.append(event) }
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
            } catch {
                warnings.append("Could not read installation history")
            }
        }
        events.sort { $0.date > $1.date }
        return HistoryResult(events: events, warnings: warnings, sources: sources)
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
                            detail: version.isEmpty ? "App crash" : "App crash · version \(version)", source: "Diagnostic report")
    }

    public static func parseInstallHistory(_ url: URL) throws -> [HistoryEvent] {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
              let size = properties.fileSize, size <= 32_000_000 else { return [] }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 32_000_000,
              let rows = try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { return [] }
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
