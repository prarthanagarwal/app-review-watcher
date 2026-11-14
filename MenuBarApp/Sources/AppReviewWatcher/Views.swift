import AppKit
import SwiftUI

// MARK: - Status styling

struct StatusStyle {
    let label: String
    let tint: Color

    static func of(_ status: String) -> StatusStyle {
        switch status {
        case "open": return .init(label: "Open", tint: .green)
        case "waitlist": return .init(label: "Waitlist", tint: .blue)
        case "full": return .init(label: "Full", tint: .red)
        case "closed": return .init(label: "Closed", tint: .gray)
        default: return .init(label: "Changed", tint: .orange)
        }
    }
}

struct StatusPill: View {
    let status: String
    var body: some View {
        let style = StatusStyle.of(status)
        HStack(spacing: 5) {
            Circle().fill(style.tint).frame(width: 6, height: 6)
            Text(style.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(style.tint)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(style.tint.opacity(0.14)))
        .fixedSize()
    }
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderView(store: store)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 14) {
                if case .stale(let since) = store.health {
                    NoticeView(title: "Checks aren't getting through",
                               detail: "The last good check was \(Time.ago(since, now: store.now)). \(store.problem)")
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Appointments")
                    if store.events.isEmpty {
                        EmptyStateView(waiting: store.health == .waiting)
                    } else {
                        ForEach(store.events) { event in
                            EventCard(event: event, now: store.now) { store.open(event.link) }
                        }
                    }
                }

                if !store.recentAlerts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("Recent activity")
                        ForEach(store.recentAlerts) { alert in
                            AlertRow(alert: alert, unseen: store.isUnseen(alert), now: store.now) {
                                store.open(alert.url.flatMap(URL.init(string:)))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            Divider().opacity(0.6)
            FooterView(store: store)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: 340)
    }
}

// MARK: - Header

struct HeaderView: View {
    @ObservedObject var store: Store

    private var accent: Color {
        if !store.openEvents.isEmpty { return .green }
        if store.health != .ok { return .orange }
        return .blue
    }
    private var icon: String {
        if !store.openEvents.isEmpty { return "calendar.badge.checkmark" }
        if case .stale = store.health { return "exclamationmark.triangle.fill" }
        return "calendar.badge.clock"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(accent.gradient))

            VStack(alignment: .leading, spacing: 2) {
                Text("App Review").font(.system(size: 15, weight: .semibold))
                Text(store.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(store.openEvents.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.green))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)

            Button(action: store.checkNow) {
                ZStack {
                    Circle().fill(Color.primary.opacity(0.07)).frame(width: 28, height: 28)
                    if store.isChecking {
                        ProgressView().controlSize(.small).scaleEffect(0.75)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(store.isChecking)
            .help(store.isChecking ? "Checking Apple's schedule…" : "Check Apple's schedule now")
        }
    }
}

// MARK: - Appointment card

struct DateTile: View {
    let date: Date?
    var body: some View {
        VStack(spacing: 0) {
            Text(date.map { Time.format($0, "MMM").uppercased() } ?? "TBA")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 15)
                .background(Color.red)
            Text(date.map { Time.format($0, "d") } ?? "–")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 40, height: 43)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }
}

struct EventCard: View {
    let event: EventInfo
    let now: Date
    let action: () -> Void
    @State private var hovering = false

    private var deadlineLine: (text: String, urgent: Bool)? {
        guard let deadline = event.deadlineDate else { return nil }
        if deadline < now { return ("Request window has closed", false) }
        let soon = deadline.timeIntervalSince(now) < 48 * 3600
        if event.isOpen && soon { return ("\(Time.left(until: deadline, now: now)) to request", true) }
        return ("Request by \(Time.format(deadline, "MMM d, h:mm a"))", false)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    DateTile(date: event.start)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.dateTitle).font(.system(size: 14, weight: .semibold))
                        if !event.subtitle.isEmpty {
                            Text(event.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        if let line = deadlineLine {
                            Text(line.text)
                                .font(.system(size: 11))
                                .foregroundStyle(line.urgent ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                        }
                    }
                    Spacer(minLength: 6)
                    StatusPill(status: event.status)
                }
                if event.isOpen {
                    HStack(spacing: 6) {
                        Text(event.status == "waitlist" ? "Join the waitlist" : "Request an appointment")
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.green.gradient))
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(event.isOpen ? Color.green.opacity(hovering ? 0.16 : 0.1) : Color.primary.opacity(hovering ? 0.08 : 0.045)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(event.isOpen ? Color.green.opacity(0.45) : Color.primary.opacity(0.07)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open this appointment on Apple's site")
    }
}

// MARK: - Supporting views

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(.tertiary)
    }
}

struct EmptyStateView: View {
    let waiting: Bool
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: waiting ? "hourglass" : "calendar")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(waiting ? "First check in progress" : "Nothing scheduled yet")
                .font(.system(size: 13, weight: .medium))
            Text(waiting ? "This usually takes under a minute." : "You'll get an alert the moment Apple posts an App Review appointment.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
    }
}

struct NoticeView: View {
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}

struct AlertRow: View {
    let alert: AlertInfo
    let unseen: Bool
    let now: Date
    let action: () -> Void
    @State private var hovering = false

    /// The panel is already titled "App Review", so drop the repeated prefix.
    private var shortTitle: String {
        let t = alert.title.replacingOccurrences(of: "App Review appointment", with: "appointment").replacingOccurrences(of: "App Review ", with: "")
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    private var symbol: (name: String, tint: Color) {
        switch alert.kind {
        case "open": return ("checkmark.seal.fill", .green)
        case "new": return ("sparkles", .blue)
        default: return ("arrow.triangle.2.circlepath", .gray)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbol.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(symbol.tint)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(symbol.tint.opacity(0.14)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(shortTitle).font(.system(size: 12, weight: unseen ? .semibold : .medium)).lineLimit(2)
                    Text(alert.message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                HStack(spacing: 5) {
                    Text(Time.ago(Time.parse(alert.time), now: now)).font(.system(size: 10)).foregroundStyle(.tertiary)
                    if unseen { Circle().fill(Color.blue).frame(width: 6, height: 6) }
                }
                .padding(.top, 3)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, -6)
    }
}

// MARK: - Footer

struct FooterView: View {
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 6) {
            if let toast = store.toast {
                Image(systemName: "info.circle.fill").font(.system(size: 11)).foregroundStyle(.blue)
                Text(toast).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Circle().fill(store.health == .ok ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(store.isChecking ? "Checking now…" : "Checked \(Time.ago(store.lastCheck, now: store.now))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if store.lastCheck != nil, !store.isChecking {
                    Text("·").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Image(systemName: store.sourceIcon).font(.system(size: 10)).foregroundStyle(.tertiary)
                    Text("via \(store.sourceLabel)").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: store.phoneAlertsOn ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                .font(.system(size: 11))
                .foregroundStyle(store.phoneAlertsOn ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                .help(store.phoneAlertsOn ? "Phone alerts are on" : "Phone alerts aren't set up")
            Menu {
                Button("Open Apple's Schedule") { store.open(Store.scheduleURL) }
                Divider()
                Button("Send Test Alert to Phone") { store.sendTestAlert() }.disabled(!store.phoneAlertsOn)
                Button("Copy Phone Alert Topic") { store.copyTopic() }.disabled(!store.phoneAlertsOn)
                Divider()
                Button("View Log") { store.open(Store.dataDir.appendingPathComponent("watch.log")) }
                if let repo = store.config.repo, let url = URL(string: "https://github.com/\(repo)/actions") {
                    Button("Open Cloud Runs on GitHub") { store.open(url) }
                }
                Divider()
                Button("Quit App Review Watcher") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}
