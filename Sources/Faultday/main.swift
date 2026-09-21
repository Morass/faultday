import Foundation
import SwiftUI
import FaultdayCore

@main
struct FaultdayApp: App {
    init() {
        if ProcessInfo.processInfo.environment["FAULTDAY_SELFTEST"] == "scan" {
            let source = HistoryReader.defaultSources()
            let result = HistoryReader.scan(reports: source.reports, installHistory: source.installs)
            print("crashes=\(result.events.filter { $0.kind == .crash }.count) installs=\(result.events.filter { $0.kind == .install }.count) warnings=\(result.warnings.count)")
            Foundation.exit(result.events.isEmpty ? 1 : 0)
        }
    }

    @State private var history: HistoryResult = {
        let source = HistoryReader.defaultSources()
        return HistoryReader.scan(reports: source.reports, installHistory: source.installs)
    }()

    var body: some Scene {
        WindowGroup("Faultday") {
            HistoryView(history: history) {
                let source = HistoryReader.defaultSources()
                history = HistoryReader.scan(reports: source.reports, installHistory: source.installs)
            }
            .frame(minWidth: 790, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
    }
}

struct HistoryView: View {
    let history: HistoryResult
    let refresh: () -> Void
    @State private var month: Date = Calendar.current.startOfMonth(for: .now)
    @State private var selectedDay: Date? = nil
    @State private var showCrashes = true
    @State private var showInstalls = true
    private let calendar = Calendar.current

    private var filtered: [HistoryEvent] {
        history.events.filter { ($0.kind == .crash && showCrashes) || ($0.kind == .install && showInstalls) }
    }
    private var displayed: [HistoryEvent] {
        guard let selectedDay else { return filtered }
        return filtered.filter { calendar.isDate($0.date, inSameDayAs: selectedDay) }
    }
    private var days: [Date] {
        let first = calendar.startOfMonth(for: month)
        let offset = (calendar.component(.weekday, from: first) + 5) % 7
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0 - offset, to: first) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Faultday").font(.largeTitle.bold())
                    Text("Your Mac’s reliability history").foregroundStyle(.secondary)
                }
                HStack {
                    Button { month = calendar.date(byAdding: .month, value: -1, to: month)! } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
                    Spacer()
                    Button { month = calendar.date(byAdding: .month, value: 1, to: month)! } label: { Image(systemName: "chevron.right") }
                }
                VStack(spacing: 7) {
                    HStack(spacing: 6) {
                        ForEach(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], id: \.self) { day in
                            Text(day).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                        ForEach(days, id: \.self) { day in dayCell(day) }
                    }
                }
                HStack(spacing: 14) {
                    Label("Crash", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    Label("Install", systemImage: "square.and.arrow.down.fill").foregroundStyle(.blue)
                }.font(.caption)
                Spacer()
                Text("Events come from records already on this Mac. Nearby events do not prove a cause.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(24).frame(width: 355).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedDay?.formatted(date: .complete, time: .omitted) ?? "All events").font(.title2.bold())
                        Text("\(displayed.count) shown · \(history.events.count) recorded").foregroundStyle(.secondary).font(.caption)
                    }
                    Spacer()
                    Button("Refresh", action: refresh)
                }.padding(20)
                HStack {
                    Toggle("Crashes", isOn: $showCrashes)
                    Toggle("Installs", isOn: $showInstalls)
                    Spacer()
                    if selectedDay != nil { Button("All days") { selectedDay = nil } }
                }.toggleStyle(.checkbox).padding(.horizontal, 20).padding(.bottom, 12)
                Divider()
                if displayed.isEmpty {
                    ContentUnavailableView(selectedDay == nil ? "No events found" : "No events that day",
                                           systemImage: "checkmark.circle",
                                           description: Text("Only readable crash reports and installation records appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(displayed) { event in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: event.kind == .crash ? "xmark.circle.fill" : "square.and.arrow.down.fill")
                                .foregroundStyle(event.kind == .crash ? .red : .blue)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.title).font(.headline)
                                Text(event.detail).foregroundStyle(.secondary)
                                Text("\(event.date.formatted(date: .abbreviated, time: .shortened)) · \(event.source)")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }.padding(.vertical, 6)
                    }.listStyle(.plain)
                }
                if !history.warnings.isEmpty {
                    Text(history.warnings.joined(separator: " · ")).font(.caption).foregroundStyle(.orange)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let events = filtered.filter { calendar.isDate($0.date, inSameDayAs: day) }
        let crashes = events.filter { $0.kind == .crash }.count
        let installs = events.count - crashes
        let isCurrentMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let selected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        return Button { selectedDay = day } label: {
            VStack(spacing: 5) {
                Text("\(calendar.component(.day, from: day))").font(.subheadline.weight(selected ? .bold : .regular))
                HStack(spacing: 2) {
                    ForEach(0..<min(crashes, 3), id: \.self) { _ in Circle().fill(.red).frame(width: 5, height: 5) }
                    ForEach(0..<min(installs, 3), id: \.self) { _ in Circle().fill(.blue).frame(width: 5, height: 5) }
                }.frame(height: 6)
            }.frame(maxWidth: .infinity).frame(height: 42)
                .background(selected ? Color.accentColor.opacity(0.22) : (events.isEmpty ? Color.clear : Color.primary.opacity(0.06)))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(isCurrentMonth ? .primary : .tertiary)
        }.buttonStyle(.plain).accessibilityLabel("\(day.formatted(date: .complete, time: .omitted)), \(crashes) crashes, \(installs) installs")
    }
}

private extension Calendar {
    func startOfMonth(for date: Date) -> Date { self.date(from: dateComponents([.year, .month], from: date))! }
}
