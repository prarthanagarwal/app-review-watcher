import AppKit
import Foundation

// The watcher script (watch.mjs) writes state.json; this app only reads it.

struct EventInfo: Codable, Identifiable, Equatable {
    var id: String
    var url: String?
    var title: String?
    var dates: String?
    var startDate: String?
    var endDate: String?
    var deadline: String?
    var deadlineText: String?
    var status: String
    var format: String?
    var statusSince: String?
}

struct AlertInfo: Codable, Identifiable, Equatable {
    var key: String
    var kind: String?
    var eventId: String?
    var title: String
    var message: String
    var url: String?
    var time: String
    var id: String { key + time }
}

struct WatcherState: Codable, Equatable {
    var source: String?
    var lastCheck: String?
    var lastAttempt: String?
    var lastError: String?
    var errorCount: Int?
    var events: [String: EventInfo]?
    var alerts: [AlertInfo]?
}

struct AppConfig: Codable, Equatable {
    var repo: String?
    var ntfyTopic: String?
    var node: String?
    var watcher: String?
}

private struct SeenFile: Codable { var seenUntil: String }

enum Health: Equatable {
    case ok
    case waiting              // no check has completed yet
    case stale(Date)          // last good check is too old
}

enum Time {
    private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFraction.date(from: s) ?? isoPlain.date(from: s)
    }

    /// "2026-11-17" as a calendar day in the local time zone.
    static func day(_ s: String?) -> Date? {
        guard let s else { return nil }
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
    }

    static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "never" }
        let m = Int(now.timeIntervalSince(date) / 60)
        if m < 1 { return "just now" }
        if m < 60 { return "\(m)m ago" }
        if m < 1440 { return "\(m / 60)h ago" }
        return "\(m / 1440)d ago"
    }

    static func left(until date: Date, now: Date) -> String {
        let m = max(0, Int(date.timeIntervalSince(now) / 60))
        if m < 60 { return "\(m)m left" }
        if m < 1440 { return "\(m / 60)h \(m % 60)m left" }
        return "\(m / 1440)d \((m % 1440) / 60)h left"
    }

    static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = pattern
        return f.string(from: date)
    }
}

extension EventInfo {
    var start: Date? { Time.day(startDate) }
    var end: Date? { Time.day(endDate) }
    var deadlineDate: Date? { Time.parse(deadline) }
    var isOpen: Bool { status == "open" || status == "waitlist" }
    var link: URL? { url.flatMap(URL.init(string:)) }

    /// "Nov 17–18", "Nov 30 – Dec 1", or "Nov 17"
    var dateTitle: String {
        guard let start else { return dates ?? "Dates to be announced" }
        guard let end, !Calendar.current.isDate(start, inSameDayAs: end) else { return Time.format(start, "MMM d") }
        if Calendar.current.component(.month, from: start) == Calendar.current.component(.month, from: end) {
            return "\(Time.format(start, "MMM d"))–\(Time.format(end, "d"))"
        }
        return "\(Time.format(start, "MMM d")) – \(Time.format(end, "MMM d"))"
    }

    var subtitle: String {
        var parts: [String] = []
        if let start {
            if let end, !Calendar.current.isDate(start, inSameDayAs: end) {
                parts.append("\(Time.format(start, "EEE"))–\(Time.format(end, "EEE"))")
            } else {
                parts.append(Time.format(start, "EEEE"))
            }
        }
        if let format { parts.append(format) }
        return parts.joined(separator: " · ")
    }
}

final class Store: ObservableObject {
    static let dataDir: URL = {
        if let custom = ProcessInfo.processInfo.environment["WATCH_DATA_DIR"] { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AppReviewWatcher")
    }()
    static let scheduleURL = URL(string: "https://developer.apple.com/events/view/upcoming-events/")!

    @Published private(set) var state = WatcherState()
    @Published private(set) var config = AppConfig()
    @Published private(set) var seenUntil = Date.distantPast
    @Published private(set) var isChecking = false
    @Published private(set) var now = Date()
    @Published var toast: String?

    private var timer: Timer?

    init(live: Bool = true) {
        reload()
        guard live else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.reload() }
    }

    // MARK: Reading

    private func read<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: Self.dataDir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func reload() {
        now = Date()
        if let s = read("state.json", as: WatcherState.self), s != state { state = s }
        if let c = read("config.json", as: AppConfig.self), c != config { config = c }
        if let seen = read("seen.json", as: SeenFile.self), let d = Time.parse(seen.seenUntil), d != seenUntil { seenUntil = d }
    }

    // MARK: Derived

    var events: [EventInfo] {
        (state.events ?? [:]).values.sorted { ($0.startDate ?? "9", $0.id) < ($1.startDate ?? "9", $1.id) }
    }
    var openEvents: [EventInfo] { events.filter(\.isOpen) }
    var lastCheck: Date? { Time.parse(state.lastCheck) }

    var recentAlerts: [AlertInfo] {
        let cutoff = now.addingTimeInterval(-7 * 86400)
        return Array((state.alerts ?? []).filter { (Time.parse($0.time) ?? .distantPast) > cutoff }.prefix(4))
    }
    func isUnseen(_ alert: AlertInfo) -> Bool { (Time.parse(alert.time) ?? .distantPast) > seenUntil }
    var unseenCount: Int { (state.alerts ?? []).filter(isUnseen).count }

    var health: Health {
        guard let lastCheck else { return .waiting }
        return now.timeIntervalSince(lastCheck) > 45 * 60 ? .stale(lastCheck) : .ok
    }

    var summary: String {
        if case .waiting = health { return "Waiting for the first check…" }
        let all = events, open = openEvents
        if !open.isEmpty { return open.count == 1 ? "1 appointment is open right now" : "\(open.count) appointments are open right now" }
        if all.isEmpty { return "No appointments listed right now" }
        if all.allSatisfy({ $0.status == "full" }) { return all.count == 1 ? "The one listed appointment is full" : "All \(all.count) listed appointments are full" }
        return "Nothing open right now"
    }

    /// Plain-language reason for a stale check (the raw error stays in the log).
    var problem: String {
        guard let error = state.lastError, !error.isEmpty else { return "This Mac may be offline or was asleep." }
        if error.localizedCaseInsensitiveContains("timeout") { return "Apple's page is taking too long to load." }
        return "Apple's page couldn't be read."
    }

    var sourceLabel: String { state.source == "cloud" ? "GitHub" : "this Mac" }
    var sourceIcon: String { state.source == "cloud" ? "cloud.fill" : "desktopcomputer" }
    var phoneAlertsOn: Bool { !(config.ntfyTopic ?? "").isEmpty }

    // MARK: Actions

    func markSeen() {
        guard unseenCount > 0 else { return }
        let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(1))
        if let data = try? JSONEncoder().encode(SeenFile(seenUntil: stamp)) {
            try? data.write(to: Self.dataDir.appendingPathComponent("seen.json"), options: .atomic)
        }
        seenUntil = Time.parse(stamp) ?? Date()
    }

    func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    func checkNow() {
        guard !isChecking else { return }
        isChecking = true
        runWatcher(["--force"]) { [weak self] _ in
            self?.isChecking = false
            self?.reload()
        }
    }

    func sendTestAlert() {
        runWatcher(["--test-notify"]) { [weak self] status in
            self?.flash(status == 0 ? "Test alert sent to your phone" : "Couldn't send the test alert")
        }
    }

    func copyTopic() {
        guard let topic = config.ntfyTopic, !topic.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(topic, forType: .string)
        flash("Topic copied — subscribe to it in the ntfy app")
    }

    func flash(_ message: String) {
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.toast == message { self?.toast = nil }
        }
    }

    private func runWatcher(_ args: [String], done: @escaping (Int32) -> Void) {
        guard let script = config.watcher, FileManager.default.fileExists(atPath: script) else {
            flash("Watcher script not found — run scripts/install-mac.sh again")
            done(-1)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.node ?? "/opt/homebrew/bin/node")
        process.arguments = [script] + args
        process.currentDirectoryURL = URL(fileURLWithPath: script).deletingLastPathComponent()
        let logURL = Self.dataDir.appendingPathComponent("watch.log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        if let log = try? FileHandle(forWritingTo: logURL) {
            log.seekToEndOfFile()
            process.standardOutput = log
            process.standardError = log
        }
        process.terminationHandler = { p in DispatchQueue.main.async { done(p.terminationStatus) } }
        do { try process.run() } catch {
            flash("Couldn't start the watcher: \(error.localizedDescription)")
            done(-1)
        }
    }
}
