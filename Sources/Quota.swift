import Foundation

// Plan limits ("quota"). Claude: live from the endpoint Claude Code's /usage calls,
// with Claude Code's own cached copy as fallback. Codex: the rate_limits block in its
// session logs. Copilot: premium requests counted from its usage table.

struct QuotaWindow: Identifiable, Codable {
    let name: String
    /// 0-100, or nil when only a count is known.
    let percent: Double?
    let detail: String?
    let resetsAt: Date?
    var id: String { name }
}

struct AgentQuota {
    var windows: [QuotaWindow]
    /// When the numbers were measured.
    var asOf: Date?
    /// Shown under the bars, e.g. why live data is unavailable.
    var note: String?
}

private func double(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

// MARK: - Claude

final class ClaudeQuotaSource {
    private var live: AgentQuota?
    private var lastAttempt = Date.distantPast
    private var lastError: String?
    private let renewer = ClaudeTokenRenewer()

    // Anthropic limits how often usage may be checked (HTTP 429). After a refusal no
    // request is sent until `nextAllowed`; the wait doubles from 5 min up to 1 hour.
    // Both the wait and the last good numbers are kept in the defaults, so a relaunch
    // neither asks again too early nor loses the numbers.
    private var nextAllowed: Date
    private var backoff: TimeInterval
    private let defaults = UserDefaults.standard

    private struct Saved: Codable { var windows: [QuotaWindow]; var asOf: Date }

    init() {
        nextAllowed = defaults.object(forKey: "claudeQuotaNextAllowed") as? Date ?? .distantPast
        backoff = defaults.double(forKey: "claudeQuotaBackoff")
        if let data = defaults.data(forKey: "claudeQuotaLast"),
           let s = try? JSONDecoder().decode(Saved.self, from: data) {
            live = AgentQuota(windows: s.windows, asOf: s.asOf, note: nil)
        }
    }

    private static let windows: [(key: String, name: String)] = [
        ("five_hour", "5-hour"), ("seven_day", "Weekly"),
        ("seven_day_opus", "Weekly Opus"), ("seven_day_sonnet", "Weekly Sonnet"),
    ]

    /// Asks the server at most every 5 minutes (every 2 minutes when `force`).
    /// `live` false uses only Claude Code's cached copy; `autoRenew` false never renews the login.
    func quota(force: Bool, live useLive: Bool = true, autoRenew: Bool = true) -> AgentQuota? {
        renewer.enabled = autoRenew
        if !useLive { lastError = nil }
        let now = Date()
        let age = now.timeIntervalSince(lastAttempt)
        if useLive && age >= (force ? 120 : 300) && now >= nextAllowed {
            lastAttempt = now
            switch fetchLive() {
            case .success(let q):
                live = q
                lastError = nil
                backoff = 0
                save(q)
            case .failure(let msg):
                lastError = msg
            }
            defaults.set(nextAllowed, forKey: "claudeQuotaNextAllowed")
            defaults.set(backoff, forKey: "claudeQuotaBackoff")
        } else if useLive && now < nextAllowed && lastError == nil {
            lastError = waitNote()
        }
        if !useLive { return cachedOnly() }
        // Prefer whichever measurement is newer: our live fetch or Claude Code's cache.
        var best = live
        if let cached = cached(), (best?.asOf ?? .distantPast) < (cached.asOf ?? .distantPast) { best = cached }
        if var b = best, let err = lastError { b.note = err; best = b }
        // A window whose reset time has passed no longer says anything about usage.
        if var b = best {
            let now = Date()
            b.windows = b.windows.map { w in
                guard let r = w.resetsAt, r <= now else { return w }
                return QuotaWindow(name: w.name, percent: nil, detail: "reset since last check", resetsAt: nil)
            }
            best = b
        }
        if best == nil, let err = lastError { return AgentQuota(windows: [], asOf: nil, note: err) }
        return best
    }

    /// Live checks switched off: Claude Code's own copy only.
    private func cachedOnly() -> AgentQuota? {
        guard var c = cached() else { return nil }
        let now = Date()
        c.windows = c.windows.map { w in
            guard let r = w.resetsAt, r <= now else { return w }
            return QuotaWindow(name: w.name, percent: nil, detail: "reset since last check", resetsAt: nil)
        }
        return c
    }

    private func save(_ q: AgentQuota) {
        if let data = try? JSONEncoder().encode(Saved(windows: q.windows, asOf: q.asOf ?? Date())) {
            defaults.set(data, forKey: "claudeQuotaLast")
        }
    }

    private func waitNote() -> String {
        "Anthropic limits how often usage can be checked; next check at "
            + nextAllowed.formatted(date: .omitted, time: .shortened) + "."
    }

    private enum Fetch { case success(AgentQuota), failure(String) }

    private func fetchLive() -> Fetch {
        guard var creds = ClaudeCredentials.read() else {
            return .failure("Not signed in to Claude Code (no Keychain token).")
        }
        if creds.isExpired {
            switch renewer.renew(creds) {
            case .success(let fresh): creds = fresh
            case .failure(let msg): return .failure(msg)
            }
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.timeoutInterval = 15
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let done = DispatchSemaphore(value: 0)
        var result: Fetch = .failure("No response from Anthropic.")
        var retryAfter: TimeInterval?
        var limited = false
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { done.signal() }
            if let err { result = .failure("Live quota unavailable: \(err.localizedDescription)"); return }
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 429 {
                limited = true
                retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                return
            }
            guard code == 200, let data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                result = .failure("Live quota unavailable (HTTP \(code))."); return
            }
            result = .success(AgentQuota(windows: Self.parse(obj), asOf: Date(), note: nil))
        }.resume()
        done.wait()
        if limited {
            backoff = min(max(backoff * 2, 300), 3600)
            nextAllowed = Date().addingTimeInterval(max(retryAfter ?? 0, backoff))
            return .failure(waitNote())
        }
        return result
    }

    /// Claude Code's own copy in ~/.claude.json, refreshed whenever /usage runs.
    private func cached() -> AgentQuota? {
        let path = FileManager.default.homeDirectoryForCurrentUser.path + "/.claude.json"
        guard let data = FileManager.default.contents(atPath: path),
              let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let c = doc["cachedUsageUtilization"] as? [String: Any],
              let u = c["utilization"] as? [String: Any] else { return nil }
        let asOf = double(c["fetchedAtMs"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return AgentQuota(windows: Self.parse(u), asOf: asOf, note: nil)
    }

    private static func parse(_ obj: [String: Any]) -> [QuotaWindow] {
        windows.compactMap { w in
            guard let d = obj[w.key] as? [String: Any], let pct = double(d["utilization"]) else { return nil }
            return QuotaWindow(name: w.name, percent: pct, detail: nil, resetsAt: ISODate.parse(d["resets_at"]))
        }
    }

}

// MARK: - Claude Code's Keychain login

/// The `claude` CLI's Keychain item, read and written through /usr/bin/security the
/// same way the CLI does, so the item and its access list stay as the CLI expects.
struct ClaudeCredentials {
    static let service = "Claude Code-credentials"

    var document: [String: Any]
    var account: String

    private var oauth: [String: Any] { document["claudeAiOauth"] as? [String: Any] ?? [:] }
    var accessToken: String { oauth["accessToken"] as? String ?? "" }
    var refreshToken: String? { oauth["refreshToken"] as? String }
    var scopes: [String] { oauth["scopes"] as? [String] ?? [] }
    var expiresAt: Date? { double(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) } }
    var isExpired: Bool { expiresAt.map { $0 <= Date().addingTimeInterval(30) } ?? false }

    static func read() -> ClaudeCredentials? {
        guard let secret = run(["find-generic-password", "-s", service, "-w"]),
              let doc = (try? JSONSerialization.jsonObject(with: secret)) as? [String: Any],
              let oauth = doc["claudeAiOauth"] as? [String: Any],
              oauth["accessToken"] is String else { return nil }
        // Account name from the item's attributes, e.g.  "acct"<blob>="name"
        var account = NSUserName()
        if let attrs = run(["find-generic-password", "-s", service]).flatMap({ String(data: $0, encoding: .utf8) }),
           let line = attrs.split(separator: "\n").first(where: { $0.contains("\"acct\"<blob>=\"") }),
           let start = line.range(of: "=\"") {
            account = String(line[start.upperBound...].dropLast())
        }
        return ClaudeCredentials(document: doc, account: account)
    }

    /// Applies an OAuth token response, keeping every other field of the item.
    func updated(with resp: [String: Any]) -> ClaudeCredentials? {
        guard let access = resp["access_token"] as? String else { return nil }
        var o = oauth
        o["accessToken"] = access
        if let r = resp["refresh_token"] as? String { o["refreshToken"] = r }
        if let secs = double(resp["expires_in"]) {
            o["expiresAt"] = Int64((Date().timeIntervalSince1970 + secs) * 1000)
        }
        if let s = resp["scope"] as? String, !s.isEmpty { o["scopes"] = s.split(separator: " ").map(String.init) }
        var doc = document
        doc["claudeAiOauth"] = o
        return ClaudeCredentials(document: doc, account: account)
    }

    /// Writes through `security -i` on stdin, so the token never appears in process arguments.
    func save() -> Bool {
        guard let json = try? JSONSerialization.data(withJSONObject: document) else { return false }
        let hex = json.map { String(format: "%02x", $0) }.joined()
        let acct = account.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let cmd = "add-generic-password -U -a \"\(acct)\" -s \"\(Self.service)\" -X \"\(hex)\"\n"
        return Self.run(["-i"], input: Data(cmd.utf8)) != nil
    }

    private static func run(_ args: [String], input: Data? = nil) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if input != nil { p.standardInput = inp }
        do { try p.run() } catch { return nil }
        if let input {
            inp.fileHandleForWriting.write(input)
            try? inp.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}

/// Renews an expired login the way the `claude` CLI does and saves the result back,
/// so the CLI picks up the new tokens on its next run.
final class ClaudeTokenRenewer {
    // The CLI's production OAuth settings (from Claude Code 2.1.282).
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private var failedAt = Date.distantPast
    var enabled = true
    /// Renewed tokens that could not be saved yet. The old refresh token may already be
    /// void, so these must reach the Keychain or the CLI ends up signed out.
    private var unsaved: ClaudeCredentials?

    enum Outcome { case success(ClaudeCredentials), failure(String) }

    /// `force` renews even a valid token (used by `--renew-claude-login`).
    func renew(_ stale: ClaudeCredentials, force: Bool = false) -> Outcome {
        if let pending = unsaved {
            if pending.save() { unsaved = nil } else { return .success(pending) }
        }
        // Read again: the CLI may have renewed it since.
        guard let creds = ClaudeCredentials.read() else { return .failure("Claude Code's Keychain login disappeared.") }
        if !creds.isExpired && !force { return .success(creds) }
        if !enabled && !force {
            return .failure("Claude Code's login token has expired; running `claude` in Terminal renews it.")
        }
        if Date().timeIntervalSince(failedAt) < 30 * 60 {
            return .failure("Claude Code's login token has expired; renewing failed, retrying later.")
        }
        guard let refresh = creds.refreshToken else {
            return .failure("Claude Code's login has no refresh token; run `claude` and sign in.")
        }

        var body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": Self.clientID]
        if !creds.scopes.isEmpty { body["scope"] = creds.scopes.joined(separator: " ") }
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let done = DispatchSemaphore(value: 0)
        var outcome: Outcome = .failure("No response while renewing the Claude login.")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { done.signal() }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard err == nil, code == 200, let data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let fresh = creds.updated(with: obj) else {
                let why = code == 400 || code == 401 ? "sign in again with `claude`" : "retrying later"
                outcome = .failure("Renewing the Claude login failed (HTTP \(code)); \(why).")
                return
            }
            outcome = .success(fresh)
        }.resume()
        done.wait()
        if case .success(let fresh) = outcome, !fresh.save() { unsaved = fresh }
        if case .failure = outcome { failedAt = Date() }
        return outcome
    }
}

// MARK: - Codex (rate_limits inside token_count events)

func codexQuota(from limits: [String: Any], at date: Date) -> AgentQuota {
    var out: [QuotaWindow] = []
    for key in ["primary", "secondary"] {
        guard let w = limits[key] as? [String: Any], let pct = double(w["used_percent"]) else { continue }
        let minutes = Int(double(w["window_minutes"]) ?? 0)
        let name: String
        switch minutes {
        case 300: name = "5-hour"
        case 10080: name = "Weekly"
        case 0: name = key.capitalized
        default: name = minutes % 1440 == 0 ? "\(minutes / 1440)-day" : "\(minutes / 60)-hour"
        }
        var reset: Date?
        if let at = double(w["resets_at"]) { reset = Date(timeIntervalSince1970: at) }
        else if let secs = double(w["resets_in_seconds"]) { reset = date.addingTimeInterval(secs) }
        out.append(QuotaWindow(name: name, percent: pct, detail: nil, resetsAt: reset))
    }
    return AgentQuota(windows: out, asOf: date, note: nil)
}

// MARK: - Formatting

func resetText(_ d: Date?, now: Date = Date()) -> String? {
    guard let d else { return nil }
    let s = Int(d.timeIntervalSince(now))
    if s <= 0 { return "reset due" }
    let days = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if days > 0 { return "resets in \(days)d \(h)h" }
    if h > 0 { return "resets in \(h)h \(m)m" }
    return "resets in \(max(m, 1))m"
}
