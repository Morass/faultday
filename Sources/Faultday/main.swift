import Foundation
import AppKit
import SwiftUI
import FaultdayCore

private enum Palette {
    static let crash = Color(red: 0.99, green: 0.38, blue: 0.43)
    static let install = Color(red: 0.30, green: 0.67, blue: 0.98)
    static let mint = Color(red: 0.35, green: 0.86, blue: 0.69)
}

private final class FaultdayDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct FaultdayApp: App {
    @NSApplicationDelegateAdaptor(FaultdayDelegate.self) private var appDelegate
    @State private var history: HistoryResult = {
        guard HistoryReader.shouldScanAtLaunch(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment) else {
            return HistoryResult(events: [], warnings: [], sources: [])
        }
        let source = HistoryReader.defaultSources()
        return HistoryReader.scan(reports: source.reports, installHistory: source.installs)
    }()

    init() {
        if CommandLine.arguments.dropFirst().contains("--help") || CommandLine.arguments.dropFirst().contains("help") {
            print("Faultday — browse crash and installation history on this Mac\n\nUsage: open Faultday.app\n       faultday --help\n\nReads existing DiagnosticReports and Apple installation history. It does not change them.\nSome app installs, hangs, and restarts are not represented.")
            Foundation.exit(0)
        }
        if CommandLine.arguments.dropFirst().contains("--demo") {
            fputs("Faultday no longer includes a sample-data mode.\n", stderr)
            Foundation.exit(2)
        }
        if ProcessInfo.processInfo.environment["FAULTDAY_SELFTEST"] == "render" {
            let captureScheme = ProcessInfo.processInfo.environment["FAULTDAY_CAPTURE_SCHEME"] == "light" ? "light" : "dark"
            NSApplication.shared.appearance = NSAppearance(named: captureScheme == "light" ? .aqua : .darkAqua)
            guard ProcessInfo.processInfo.environment["FAULTDAY_REPORTS_DIR"] != nil else { Foundation.exit(2) }
            let source = HistoryReader.defaultSources()
            let result = HistoryReader.scan(reports: source.reports, installHistory: source.installs)
            let view = NSHostingView(rootView: HistoryView(history: result, appearanceOverride: captureScheme, refresh: {}).frame(width: 1100, height: 720))
            view.frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            window.displayIfNeeded()
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
                  let path = ProcessInfo.processInfo.environment["FAULTDAY_CAPTURE_PATH"] else { Foundation.exit(2) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { Foundation.exit(2) }
            do { try png.write(to: URL(fileURLWithPath: path)) } catch { Foundation.exit(2) }
            print("rendered=\(png.count)")
            Foundation.exit(png.count > 10000 ? 0 : 2)
        }
        if ProcessInfo.processInfo.environment["FAULTDAY_SELFTEST"] == "scan" {
            let source = HistoryReader.defaultSources()
            let result = HistoryReader.scan(reports: source.reports, installHistory: source.installs)
            print("crashes=\(result.events.filter { $0.kind == .crash }.count) installs=\(result.events.filter { $0.kind == .install }.count) other=\(result.otherReports) warnings=\(result.warnings.count)")
            Foundation.exit(result.events.isEmpty ? 1 : 0)
        }
    }

    var body: some Scene {
        WindowGroup("Faultday") {
            HistoryView(history: history, refresh: {
                let source = HistoryReader.defaultSources()
                history = HistoryReader.scan(reports: source.reports, installHistory: source.installs)
            })
            .frame(minWidth: 920, minHeight: 650)
        }
        .windowResizability(.contentMinSize)
    }
}

struct HistoryView: View {
    let history: HistoryResult
    let appearanceOverride: String?
    let refresh: () -> Void
    @AppStorage("appearance") private var appearance = "dark"
    @Environment(\.colorScheme) private var colorScheme
    @State private var month: Date
    @State private var selectedDay: Date?
    @State private var selectedHour: Int? = nil
    @State private var showCrashes = true
    @State private var showInstalls = true
    @State private var reportOpenError = false
    private let calendar = Calendar.current

    init(history: HistoryResult, appearanceOverride: String? = nil, refresh: @escaping () -> Void) {
        self.history = history
        self.appearanceOverride = appearanceOverride
        self.refresh = refresh
        let first = history.events.first?.date ?? .now
        _selectedDay = State(initialValue: history.events.first?.date)
        _month = State(initialValue: Calendar.current.startOfMonth(for: first))
    }

    private var surface: Color { colorScheme == .dark ? Color(red: 0.11, green: 0.16, blue: 0.21) : Color(red: 0.95, green: 0.97, blue: 0.99) }
    private var base: Color { colorScheme == .dark ? Color(red: 0.065, green: 0.09, blue: 0.13) : .white }
    private var muted: Color { colorScheme == .dark ? Color(red: 0.62, green: 0.69, blue: 0.76) : Color(red: 0.39, green: 0.45, blue: 0.53) }
    private var filtered: [HistoryEvent] {
        HistorySeries.matching(history.events, kinds: enabledKinds, day: nil, hour: nil)
    }
    private var displayed: [HistoryEvent] {
        HistorySeries.matching(history.events, kinds: enabledKinds, day: selectedDay, hour: selectedHour)
    }
    private var enabledKinds: Set<EventKind> {
        var kinds = Set<EventKind>()
        if showCrashes { kinds.insert(.crash) }
        if showInstalls { kinds.insert(.install) }
        return kinds
    }
    private var days: [Date] {
        let first = calendar.startOfMonth(for: month)
        let offset = (calendar.component(.weekday, from: first) + 5) % 7
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0 - offset, to: first) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)).frame(width: 1)
            content
        }
        .background(base)
        .preferredColorScheme((appearanceOverride ?? appearance) == "system" ? nil : ((appearanceOverride ?? appearance) == "light" ? .light : .dark))
        .alert("Could not open report", isPresented: $reportOpenError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The report may have been moved or removed. Refresh and try again.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Image(systemName: "waveform.path.ecg.rectangle").font(.title2).foregroundStyle(Palette.mint)
                    Text("Faultday").font(.system(size: 29, weight: .bold, design: .rounded))
                }
                Text("A clearer view of what happened").font(.subheadline).foregroundStyle(muted)
            }
            HStack {
                Button { changeMonth(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
                Spacer()
                Button { changeMonth(1) } label: { Image(systemName: "chevron.right") }
            }.buttonStyle(.borderless)
            VStack(spacing: 7) {
                HStack(spacing: 6) {
                    ForEach(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], id: \.self) { day in
                        Text(day).font(.caption2.weight(.medium)).foregroundStyle(muted).frame(maxWidth: .infinity)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(days, id: \.self) { day in dayCell(day) }
                }
            }
            HStack(spacing: 15) {
                Label("Crash", systemImage: "circle.fill").foregroundStyle(Palette.crash)
                Label("Install", systemImage: "circle.fill").foregroundStyle(Palette.install)
            }.font(.caption.weight(.medium))
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 11) {
                Text("\(history.events.filter { $0.kind == .crash }.count) saved app crash reports found. \(history.otherReports) other diagnostic reports are outside this view.")
                    .font(.caption).foregroundStyle(muted)
                HStack {
                    Text("Appearance").foregroundStyle(muted)
                    Spacer()
                    Picker("Appearance", selection: $appearance) {
                        Text("Dark").tag("dark")
                        Text("Light").tag("light")
                        Text("System").tag("system")
                    }.labelsHidden().frame(width: 105)
                }.font(.caption)
                Text("Apple crash and installer records only. An install near a crash does not prove a cause.")
                    .font(.caption).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(23).frame(width: 338)
        .background(surface)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 9) {
                        Text(selectedDay?.formatted(date: .complete, time: .omitted) ?? "All events")
                            .font(.system(size: 23, weight: .bold, design: .rounded))
                    }
                    Text(selectedDay == nil ? "Recent recorded activity" : "Recorded activity through the day")
                        .font(.subheadline).foregroundStyle(muted)
                }
                Spacer()
                Button("Refresh", action: refresh).buttonStyle(.bordered)
            }
            HStack(spacing: 10) {
                statTile(title: "CRASHES", value: displayed.filter { $0.kind == .crash }.count, tint: Palette.crash, icon: "xmark.circle.fill")
                statTile(title: "INSTALLS", value: displayed.filter { $0.kind == .install }.count, tint: Palette.install, icon: "square.and.arrow.down.fill")
                statTile(title: "EVENTS", value: displayed.count, tint: Palette.mint, icon: "chart.bar.fill")
            }
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text(selectedDay == nil ? "Recent days" : "Activity by hour").font(.headline)
                    Spacer()
                    Text(selectedDay == nil ? "last 14 days" : "local time · 00–23")
                        .font(.caption).foregroundStyle(muted)
                }
                if let selectedDay {
                    hourlyChart(for: selectedDay)
                } else {
                    recentChart()
                }
            }
            .padding(16)
            .background(surface, in: RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 14) {
                Toggle("Crashes", isOn: $showCrashes).tint(Palette.crash)
                Toggle("Installs", isOn: $showInstalls).tint(Palette.install)
                if let selectedHour {
                    Button(String(format: "%02d:00 ×", selectedHour)) { self.selectedHour = nil }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if selectedDay != nil { Button("All days") { selectedDay = nil; selectedHour = nil }.buttonStyle(.plain).foregroundStyle(Palette.install) }
            }.toggleStyle(.checkbox).font(.subheadline)
            HStack {
                Text("EVENTS").font(.caption.weight(.bold)).tracking(1.5).foregroundStyle(muted)
                Spacer()
                Text("\(displayed.count) shown · \(history.events.count) recorded").font(.caption).foregroundStyle(muted)
            }
            if displayed.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(Palette.mint)
                    Text("No recorded events here").font(.headline)
                    Text(HistorySeries.emptyStateMessage(kinds: enabledKinds))
                        .font(.caption).foregroundStyle(muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(displayed) { event in
                            eventRow(event)
                            Divider().overlay(muted.opacity(0.15))
                        }
                    }
                }
                .background(surface, in: RoundedRectangle(cornerRadius: 12))
            }
            if !history.warnings.isEmpty {
                Text(history.warnings.joined(separator: " · ")).font(.caption).foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func statTile(title: String, value: Int, tint: Color, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2.bold()).tracking(1).foregroundStyle(muted)
                Text("\(value)").font(.title2.bold()).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(13).frame(maxWidth: .infinity)
        .background(surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func hourlyChart(for day: Date) -> some View {
        let buckets = HistorySeries.hourly(filtered, on: day)
        let maximum = max(1, buckets.map(\.total).max() ?? 1)
        return VStack(spacing: 7) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(buckets, id: \.hour) { bucket in
                    Button {
                        selectedHour = selectedHour == bucket.hour ? nil : bucket.hour
                    } label: {
                        VStack(spacing: 2) {
                            Spacer(minLength: 0)
                            if bucket.installs > 0 {
                                RoundedRectangle(cornerRadius: 3).fill(Palette.install)
                                    .frame(height: max(4, CGFloat(bucket.installs) / CGFloat(maximum) * 74))
                            }
                            if bucket.crashes > 0 {
                                RoundedRectangle(cornerRadius: 3).fill(Palette.crash)
                                    .frame(height: max(4, CGFloat(bucket.crashes) / CGFloat(maximum) * 74))
                            }
                            if bucket.total == 0 { Rectangle().fill(muted.opacity(0.16)).frame(height: 2) }
                        }
                        .frame(maxWidth: .infinity).frame(height: 84)
                        .padding(.horizontal, 2)
                        .background(selectedHour == bucket.hour ? Palette.mint.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help(String(format: "%02d:00 · %d crashes · %d installs", bucket.hour, bucket.crashes, bucket.installs))
                    .accessibilityLabel(String(format: "%02d:00, %d crashes, %d installs", bucket.hour, bucket.crashes, bucket.installs))
                }
            }
            HStack {
                Text("00")
                Spacer()
                Text("06")
                Spacer()
                Text("12")
                Spacer()
                Text("18")
                Spacer()
                Text("23")
            }.font(.caption2.monospacedDigit()).foregroundStyle(muted)
        }
    }

    private func recentChart() -> some View {
        let today = calendar.startOfDay(for: .now)
        let dates = (-13...0).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        let totals = dates.map { day in filtered.filter { calendar.isDate($0.date, inSameDayAs: day) }.count }
        let maximum = max(1, totals.max() ?? 1)
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(dates.enumerated()), id: \.offset) { index, day in
                Button { selectedDay = day; selectedHour = nil; month = calendar.startOfMonth(for: day) } label: {
                    VStack(spacing: 5) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(totals[index] == 0 ? muted.opacity(0.16) : Palette.mint)
                            .frame(height: totals[index] == 0 ? 2 : max(5, CGFloat(totals[index]) / CGFloat(maximum) * 78))
                        Text(index.isMultiple(of: 2) ? day.formatted(.dateTime.day()) : " ")
                            .font(.caption2.monospacedDigit()).foregroundStyle(muted)
                    }.frame(maxWidth: .infinity).frame(height: 103)
                }.buttonStyle(.plain).help("\(day.formatted(date: .abbreviated, time: .omitted)): \(totals[index]) events")
            }
        }
    }

    @ViewBuilder private func eventRow(_ event: HistoryEvent) -> some View {
        if let path = event.reportPath {
            Button {
                if !NSWorkspace.shared.open(URL(fileURLWithPath: path)) { reportOpenError = true }
            } label: {
                eventRowContent(event, openable: true)
            }
            .buttonStyle(.plain)
            .help("Open crash report")
            .accessibilityLabel("Open crash report for \(event.title)")
        } else {
            eventRowContent(event, openable: false)
        }
    }

    private func eventRowContent(_ event: HistoryEvent, openable: Bool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: event.kind == .crash ? "xmark.circle.fill" : "square.and.arrow.down.fill")
                .foregroundStyle(event.kind == .crash ? Palette.crash : Palette.install)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(event.title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(event.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption.monospacedDigit()).foregroundStyle(muted)
                }
                Text(event.detail).font(.caption).foregroundStyle(muted)
                Text(event.source).font(.caption2).foregroundStyle(muted.opacity(0.8))
            }
            if openable { Image(systemName: "arrow.up.right.square").foregroundStyle(Palette.install).font(.caption) }
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func dayCell(_ day: Date) -> some View {
        let events = filtered.filter { calendar.isDate($0.date, inSameDayAs: day) }
        let crashes = events.filter { $0.kind == .crash }.count
        let installs = events.count - crashes
        let isCurrentMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let selected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        return Button { selectedDay = day; selectedHour = nil } label: {
            VStack(spacing: 5) {
                Text("\(calendar.component(.day, from: day))").font(.subheadline.weight(selected ? .bold : .regular))
                HStack(spacing: 3) {
                    ForEach(0..<min(crashes, 3), id: \.self) { _ in Circle().fill(Palette.crash).frame(width: 5, height: 5) }
                    ForEach(0..<min(installs, 3), id: \.self) { _ in Circle().fill(Palette.install).frame(width: 5, height: 5) }
                }.frame(height: 6)
            }
            .frame(maxWidth: .infinity).frame(height: 42)
            .background(selected ? Palette.install.opacity(0.24) : (events.isEmpty ? .clear : Palette.mint.opacity(0.07)), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(isCurrentMonth ? .primary : .tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(day.formatted(date: .complete, time: .omitted)), \(crashes) crashes, \(installs) installs")
    }

    private func changeMonth(_ offset: Int) {
        if let next = calendar.date(byAdding: .month, value: offset, to: month) { month = next }
    }

}

private extension Calendar {
    func startOfMonth(for date: Date) -> Date { self.date(from: dateComponents([.year, .month], from: date))! }
}
