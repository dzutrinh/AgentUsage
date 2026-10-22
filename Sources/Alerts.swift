import Foundation
import UserNotifications

// Quota alerts: a notification when a window crosses 80% or 95% (once each per
// window), and when a window resets. State persists across launches so a
// restart never repeats an alert.

struct AlertState: Codable, Equatable {
    /// Highest threshold already notified in the current window (0, 80 or 95).
    var level: Int
    /// End of the current window, as last seen.
    var resetsAt: Date?
}

struct QuotaAlert: Equatable {
    let title: String
    let body: String
}

enum ResetAlerts: String {
    case afterWarning, always, never
}

enum AlertRules {
    static let thresholds = [95, 80] // highest first

    /// Pure function: compares an agent's windows with what was seen before.
    static func evaluate(agent: Agent, quota: AgentQuota, state: [String: AlertState],
                         now: Date = Date(), resets: ResetAlerts = .afterWarning)
        -> (state: [String: AlertState], alerts: [QuotaAlert])
    {
        var state = state
        var alerts: [QuotaAlert] = []
        let prefix = agent.rawValue + "/"
        // Live or recent numbers only; an old cached copy must not trigger warnings.
        let fresh = quota.asOf.map { now.timeIntervalSince($0) < 15 * 60 } ?? false

        func resetIfDue(_ key: String, _ name: String, newResetsAt: Date?) {
            guard let s = state[key], let r = s.resetsAt else { return }
            let passed = now >= r
            let moved = newResetsAt.map { $0.timeIntervalSince(r) > 120 } ?? false
            guard passed || moved else { return }
            if resets == .always || (resets == .afterWarning && s.level > 0) {
                alerts.append(QuotaAlert(title: "\(agent.rawValue): \(name) limit reset",
                                         body: "Back to a full \(name.lowercased()) quota."))
            }
            state[key] = AlertState(level: 0, resetsAt: nil)
        }

        for w in quota.windows {
            let key = prefix + w.name
            resetIfDue(key, w.name, newResetsAt: fresh ? w.resetsAt : nil)
            var s = state[key] ?? AlertState(level: 0, resetsAt: nil)
            if fresh, let p = w.percent {
                if let t = thresholds.first(where: { p >= Double($0) }), t > s.level {
                    let when = resetText(w.resetsAt, now: now).map { $0.prefix(1).uppercased() + $0.dropFirst() + "." }
                    alerts.append(QuotaAlert(title: "\(agent.rawValue): \(w.name) limit at \(Int(p.rounded()))%",
                                             body: when ?? "Approaching the limit."))
                    s.level = t
                }
                if let r = w.resetsAt { s.resetsAt = r }
            } else if s.resetsAt == nil, fresh, let r = w.resetsAt {
                s.resetsAt = r
            }
            state[key] = s
        }

        // Windows that no longer appear still reset on time.
        let current = Set(quota.windows.map { prefix + $0.name })
        for key in state.keys where key.hasPrefix(prefix) && !current.contains(key) {
            resetIfDue(key, String(key.dropFirst(prefix.count)), newResetsAt: nil)
            if state[key]?.resetsAt == nil && state[key]?.level == 0 { state[key] = nil }
        }
        return (state, alerts)
    }
}

/// Posts notifications. Does nothing outside an app bundle (e.g. test harnesses).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    func setUp() {
        guard available else { return }
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func send(_ a: QuotaAlert) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = a.title
        content.body = a.body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    func sendTest() {
        send(QuotaAlert(title: "Agent Usage: test alert", body: "Quota alerts will look like this."))
    }

    /// Show banners even while the menu is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}
