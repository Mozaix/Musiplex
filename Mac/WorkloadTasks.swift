import AppKit
import Foundation
import Observation
import SwiftUI

/// School tasks from Workload for the notch's Calendar tab: from the linked Linux server
/// when Musiplex is linked to one (the hub), otherwise from this Mac's own task list.
/// Refreshed when the tab opens and every 5 minutes. Only looks for tasks when Workload
/// is installed; otherwise the tab offers to get it.
@MainActor @Observable
final class WorkloadTasks {
    struct Item: Decodable, Identifiable, Equatable {
        let id: String
        let title: String
        let due: String?
        let urgency: String
        let done: Bool
        let deleted: Bool
        let deletedBy: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            due = try c.decodeIfPresent(String.self, forKey: .due)
            urgency = try c.decodeIfPresent(String.self, forKey: .urgency) ?? "green"
            done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
            deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
            deletedBy = try c.decodeIfPresent(String.self, forKey: .deletedBy)
        }
        enum CodingKeys: String, CodingKey { case id, title, due, urgency, done, deleted, deletedBy }
    }

    struct Day: Identifiable {
        let id: String
        let title: String
        let items: [Item]
    }

    private(set) var items: [Item] = []
    private(set) var loaded = false
    private(set) var failed = false
    private(set) var updated: Date?
    @ObservationIgnored private weak var linked: LinkedServer?
    @ObservationIgnored private var timer: Timer?

    init(linked: LinkedServer) {
        self.linked = linked
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        timer?.tolerance = 30
        Task { await refresh() }
    }

    var isLinked: Bool { linked?.isLinked == true }
    var hubName: String { isLinked ? (linked?.name ?? "your linked server") : "this Mac" }

    /// Workload is on this Mac (it was ticked in the installer, or installed later).
    static var installed: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.musiplex.workload") != nil
    }
    static let download = URL(string: "https://github.com/Mozaix/Musiplex/releases/latest")!

    func refresh() async {
        guard Self.installed else { loaded = true; return }
        struct Reply: Decodable { let tasks: [Item] }
        let data: Data? = if let linked, linked.isLinked { await linked.get("tasks") } else { TaskHub.shared.snapshot() }
        if let data, let reply = try? JSONDecoder().decode(Reply.self, from: data) {
            items = reply.tasks.filter { !$0.done && !$0.deleted }
            failed = false
            updated = Date()
        } else {
            failed = true
        }
        loaded = true
    }

    // MARK: Grouping: Overdue, Today, Tomorrow, weekdays, then dates; no date last

    /// "2026-11-28" (all day) or "2026-11-28T23:59", local time.
    static func date(_ due: String?) -> (date: Date, allDay: Bool)? {
        guard let due, !due.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        if due.contains("T") {
            f.dateFormat = "yyyy-MM-dd'T'HH:mm"
            if let d = f.date(from: String(due.prefix(16))) { return (d, false) }
        }
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(due.prefix(10))).map { ($0, true) }
    }

    static func isOverdue(_ item: Item, now: Date = Date()) -> Bool {
        guard let d = date(item.due) else { return false }
        return d.allDay ? Calendar.current.startOfDay(for: d.date) < Calendar.current.startOfDay(for: now) : d.date < now
    }

    var days: [Day] {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let sorted = items.sorted { (Self.date($0.due)?.date ?? .distantFuture, $0.title) < (Self.date($1.due)?.date ?? .distantFuture, $1.title) }
        var out: [Day] = []
        let overdue = sorted.filter { Self.isOverdue($0, now: now) }
        if !overdue.isEmpty { out.append(Day(id: "overdue", title: "Overdue", items: overdue)) }
        var groups: [(key: Date, items: [Item])] = []
        for item in sorted where !Self.isOverdue(item, now: now) {
            guard let d = Self.date(item.due) else { continue }
            let key = cal.startOfDay(for: d.date)
            if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].items.append(item) } else { groups.append((key, [item])) }
        }
        let weekday = DateFormatter(); weekday.dateFormat = "EEEE"
        let dated = DateFormatter(); dated.dateFormat = "EEE, MMM d"
        for g in groups {
            let days = cal.dateComponents([.day], from: today, to: g.key).day ?? 0
            let title = days == 0 ? "Today" : days == 1 ? "Tomorrow" : days < 7 ? weekday.string(from: g.key) : dated.string(from: g.key)
            out.append(Day(id: "\(g.key.timeIntervalSince1970)", title: title, items: g.items))
        }
        let undated = sorted.filter { $0.due == nil || $0.due?.isEmpty == true }
        if !undated.isEmpty { out.append(Day(id: "none", title: "No date", items: undated)) }
        return out
    }

    static func color(_ item: Item) -> Color {
        if isOverdue(item) { return Color(red: 0xD4 / 255, green: 0x4C / 255, blue: 0x47 / 255) }
        switch item.urgency {
        case "red": return Color(red: 0xD4 / 255, green: 0x4C / 255, blue: 0x47 / 255)
        case "yellow": return Color(red: 0xCB / 255, green: 0x91 / 255, blue: 0x2F / 255)
        default: return Color(red: 0x44 / 255, green: 0x83 / 255, blue: 0x61 / 255)
        }
    }

    static func time(_ item: Item) -> String {
        guard let d = date(item.due), !d.allDay else { return "All day" }
        return d.date.formatted(date: .omitted, time: .shortened)
    }
}

/// The notch's Calendar tab: your open Workload tasks by day, overdue first.
struct NotchCalendar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let work = model.workload
        Group {
            if !WorkloadTasks.installed {
                getWorkload
            } else if !work.loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if work.items.isEmpty {
                hint("checkmark.circle", work.failed ? "Couldn't reach \(work.hubName)." : "Nothing due. Enjoy it.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(work.days) { day in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(day.title.uppercased())
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced)).kerning(1.5)
                                    .foregroundStyle(day.id == "overdue" ? WorkloadTasks.color(day.items[0]) : Theme.dim)
                                ForEach(day.items) { item in
                                    HStack(spacing: 8) {
                                        Circle().fill(WorkloadTasks.color(item)).frame(width: 7, height: 7)
                                        Text(item.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                        Spacer(minLength: 8)
                                        Text(WorkloadTasks.time(item)).font(.system(size: 11)).foregroundStyle(Theme.dim)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
        .task { await work.refresh() }
    }

    /// Workload isn't on this Mac: a short guided step to get it. Once installed it connects
    /// to this Musiplex by itself (no PIN) and its tasks show up here.
    private var getWorkload: some View {
        HStack(spacing: 18) {
            Image(systemName: "checklist").font(.system(size: 34, weight: .semibold)).foregroundStyle(Theme.gradient)
            VStack(alignment: .leading, spacing: 6) {
                Text("Add Workload for your tasks").font(.system(size: 14, weight: .bold))
                Text("1. Download the Musiplex installer and tick Workload.\n2. Open Workload once: it connects to Musiplex by itself.\n3. Your deadlines show up here, by day.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                Button("Get Workload") { NSWorkspace.shared.open(WorkloadTasks.download) }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func hint(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(Theme.dim)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
