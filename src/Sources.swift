import Foundation
import SQLite3

// Readers for each agent's local logs. Every reader is incremental: a file is
// only re-read when its size or modification time changed, and append-only
// JSONL files are read from where the last scan stopped.

protocol UsageSource: AnyObject {
    var agent: Agent { get }
    /// Folders or files this agent writes to; the agent counts as present if any exists.
    var roots: [String] { get }
    func collect() -> [UsageEvent]
}

extension UsageSource {
    var isPresent: Bool { roots.contains { FileManager.default.fileExists(atPath: $0) } }
}

private let home = FileManager.default.homeDirectoryForCurrentUser.path

private func env(_ name: String) -> String? {
    guard let v = ProcessInfo.processInfo.environment[name], !v.isEmpty else { return nil }
    return v
}

private func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }

enum ISODate {
    private static let frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()
    private static let sqlite: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func parse(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        if let d = frac.date(from: s) ?? plain.date(from: s) ?? sqlite.date(from: s) { return d }
        // Microsecond timestamps ("…00.427644+00:00"): drop the fraction.
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
            return plain.date(from: s.replacingCharacters(in: r, with: ""))
        }
        return nil
    }
}

// MARK: - Line scanner

enum LineScanner {
    /// Calls `body` for every complete line after `offset` that contains one of `needles`.
    /// Returns the offset just past the last complete line, or nil if the file can't be read.
    static func scan(path: String, from offset: UInt64, needles: [String], _ body: (Data) -> Void) -> UInt64? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        do { try fh.seek(toOffset: offset) } catch { return nil }
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return offset }

        let needleBytes = needles.map { Array($0.utf8) }
        var consumed = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            var start = 0
            while start < count {
                guard let nl = memchr(base + start, 0x0A, count - start) else { break }
                let end = base.distance(to: UnsafeRawPointer(nl))
                let len = end - start
                if len > 0 {
                    let line = base + start
                    let hit = needleBytes.isEmpty || needleBytes.contains { n in
                        n.withUnsafeBytes { memmem(line, len, $0.baseAddress, n.count) != nil }
                    }
                    if hit { body(Data(bytes: line, count: len)) }
                }
                start = end + 1
            }
            consumed = start
        }
        return offset + UInt64(consumed)
    }
}

// MARK: - JSONL base

final class ParseContext {
    var model: String?
    var lastTotal = -1
    /// The file being parsed (Grok reads its session's summary.json beside it).
    var path = ""
    var loadedMeta = false
}

class JSONLSource: UsageSource {
    let agent: Agent
    init(agent: Agent) { self.agent = agent }

    var roots: [String] { [] }
    var needles: [String] { [] }
    func accepts(_ path: String) -> Bool { path.hasSuffix(".jsonl") }
    func parse(_ obj: [String: Any], _ ctx: ParseContext) -> UsageEvent? { nil }
    /// Override when one line holds several requests (e.g. one per model).
    func parseAll(_ obj: [String: Any], _ ctx: ParseContext) -> [UsageEvent] {
        parse(obj, ctx).map { [$0] } ?? []
    }
    /// Override for files that are not JSON Lines; return nil to use the line scanner.
    func parseWhole(path: String) -> [UsageEvent]? { nil }

    private struct Entry {
        var size: UInt64 = 0
        var mtime = Date.distantPast
        var offset: UInt64 = 0
        var events: [UsageEvent] = []
        var ctx = ParseContext()
    }
    private var entries: [String: Entry] = [:]

    private func files() -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        for root in roots {
            guard let walker = fm.enumerator(atPath: root) else { continue }
            while let rel = walker.nextObject() as? String {
                let p = root + "/" + rel
                if accepts(p) { out.append(p) }
            }
        }
        return out
    }

    func collect() -> [UsageEvent] {
        var out: [UsageEvent] = []
        var seen = Set<String>()
        for path in files() {
            seen.insert(path)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let mtime = attrs[.modificationDate] as? Date ?? .distantPast

            var e = entries[path] ?? Entry()
            if e.size == size && e.mtime == mtime { out += e.events; continue }
            if size < e.size { e = Entry() } // rewritten or truncated: start over

            if let whole = parseWhole(path: path) {
                e.events = whole
                e.offset = size
            } else {
                let ctx = e.ctx
                ctx.path = path
                var fresh: [UsageEvent] = []
                if let next = LineScanner.scan(path: path, from: e.offset, needles: needles, { line in
                    if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                        fresh += self.parseAll(obj, ctx)
                    }
                }) {
                    e.offset = next
                    e.events += fresh
                }
            }
            e.size = size
            e.mtime = mtime
            entries[path] = e
            out += e.events
        }
        entries = entries.filter { seen.contains($0.key) }
        return out
    }
}

// MARK: - Claude Code (~/.claude/projects/**/*.jsonl)

final class ClaudeSource: JSONLSource {
    init() { super.init(agent: .claude) }

    override var roots: [String] {
        var r = [home + "/.claude/projects", home + "/.config/claude/projects"]
        if let dirs = env("CLAUDE_CONFIG_DIR") {
            r += dirs.split(separator: ",").map { String($0) + "/projects" }
        }
        return Array(Set(r))
    }
    override var needles: [String] { ["\"output_tokens\""] }

    override func parse(_ obj: [String: Any], _ ctx: ParseContext) -> UsageEvent? {
        guard obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any],
              let u = msg["usage"] as? [String: Any],
              let date = ISODate.parse(obj["timestamp"]) else { return nil }
        let model = msg["model"] as? String ?? "unknown"
        if model == "<synthetic>" { return nil }
        let mid = msg["id"] as? String
        let rid = obj["requestId"] as? String
        let key = (mid == nil && rid == nil) ? nil : "c:\(mid ?? ""):\(rid ?? "")"
        return UsageEvent(agent: .claude, model: model, date: date,
                          input: int(u["input_tokens"]),
                          output: int(u["output_tokens"]),
                          cacheRead: int(u["cache_read_input_tokens"]),
                          cacheWrite: int(u["cache_creation_input_tokens"]),
                          key: key)
    }
}

// MARK: - OpenAI Codex CLI (~/.codex/sessions/**/rollout-*.jsonl)

final class CodexSource: JSONLSource {
    init() { super.init(agent: .codex) }

    /// Newest rate_limits block seen in any session log.
    private(set) var latestLimits: (date: Date, limits: [String: Any])?

    var quota: AgentQuota? { latestLimits.map { codexQuota(from: $0.limits, at: $0.date) } }

    override var roots: [String] {
        let base = env("CODEX_HOME") ?? home + "/.codex"
        return [base + "/sessions", base + "/archived_sessions"]
    }
    override var needles: [String] { ["\"token_count\"", "\"turn_context\"", "\"session_meta\""] }

    override func parse(_ obj: [String: Any], _ ctx: ParseContext) -> UsageEvent? {
        guard let payload = obj["payload"] as? [String: Any] else { return nil }
        let type = obj["type"] as? String
        if type == "turn_context" || type == "session_meta" {
            if let m = payload["model"] as? String { ctx.model = m }
            return nil
        }
        guard type == "event_msg", payload["type"] as? String == "token_count",
              let date = ISODate.parse(obj["timestamp"]) else { return nil }
        if let limits = payload["rate_limits"] as? [String: Any],
           date >= (latestLimits?.date ?? .distantPast) {
            latestLimits = (date, limits)
        }
        guard let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any] else { return nil }
        // Codex repeats token_count events; only count one when the running total moves.
        if let total = info["total_token_usage"] as? [String: Any] {
            let t = int(total["total_tokens"])
            if t == ctx.lastTotal { return nil }
            ctx.lastTotal = t
        }
        let cached = int(last["cached_input_tokens"])
        return UsageEvent(agent: .codex, model: ctx.model ?? "unknown", date: date,
                          input: max(0, int(last["input_tokens"]) - cached),
                          output: int(last["output_tokens"]),
                          cacheRead: cached, cacheWrite: 0, key: nil)
    }
}

// MARK: - Gemini CLI (~/.gemini/tmp/<project>/chats/*.json[l])

final class GeminiSource: JSONLSource {
    init() { super.init(agent: .gemini) }

    override var roots: [String] { [home + "/.gemini/tmp"] }
    override var needles: [String] { ["\"tokens\""] }
    override func accepts(_ path: String) -> Bool {
        path.contains("/chats/") && (path.hasSuffix(".jsonl") || path.hasSuffix(".json"))
    }

    override func parse(_ obj: [String: Any], _ ctx: ParseContext) -> UsageEvent? {
        guard let t = obj["tokens"] as? [String: Any],
              let date = ISODate.parse(obj["timestamp"]) else { return nil }
        let cached = int(t["cached"])
        let id = obj["id"] as? String
        return UsageEvent(agent: .gemini, model: obj["model"] as? String ?? "unknown", date: date,
                          input: max(0, int(t["input"]) - cached),
                          output: int(t["output"]) + int(t["thoughts"]),
                          cacheRead: cached, cacheWrite: 0,
                          key: id.map { "g:" + $0 })
    }

    // Older Gemini CLI versions wrote one JSON document with a `messages` array.
    override func parseWhole(path: String) -> [UsageEvent]? {
        guard path.hasSuffix(".json") else { return nil }
        guard let data = FileManager.default.contents(atPath: path),
              let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let msgs = doc["messages"] as? [[String: Any]] else { return [] }
        let ctx = ParseContext()
        return msgs.compactMap { parse($0, ctx) }
    }
}

// MARK: - Grok Build CLI ($GROK_HOME or ~/.grok/sessions/<cwd>/<session>/updates.jsonl)
// Format as read by ccusage's Grok adapter: one `turn_completed` update per finished
// turn, usage split per model in `modelUsage`; inputTokens includes cached tokens.

final class GrokSource: JSONLSource {
    init() { super.init(agent: .grok) }

    override var roots: [String] {
        [(env("GROK_HOME") ?? home + "/.grok") + "/sessions"]
    }
    override var needles: [String] { ["\"turn_completed\""] }
    override func accepts(_ path: String) -> Bool { path.hasSuffix("/updates.jsonl") }

    override func parseAll(_ obj: [String: Any], _ ctx: ParseContext) -> [UsageEvent] {
        guard let params = obj["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              update["sessionUpdate"] as? String == "turn_completed",
              let usage = update["usage"] as? [String: Any] else { return [] }

        let meta = params["_meta"] as? [String: Any]
        var date: Date?
        if let ms = (meta?["agentTimestampMs"] as? NSNumber)?.doubleValue, ms > 0 {
            date = Date(timeIntervalSince1970: ms / 1000)
        } else if let s = (obj["timestamp"] as? NSNumber)?.doubleValue, s > 0 {
            date = Date(timeIntervalSince1970: s) // envelope timestamp is Unix seconds
        }
        guard let date else { return [] }

        let session = params["sessionId"] as? String ?? ""
        let eventId = meta?["eventId"] as? String

        var rows: [(String, [String: Any])] = []
        if let byModel = usage["modelUsage"] as? [String: Any], !byModel.isEmpty {
            rows = byModel.compactMap { k, v in (v as? [String: Any]).map { (k, $0) } }.sorted { $0.0 < $1.0 }
        } else {
            rows = [(defaultModel(ctx), usage)]
        }
        return rows.compactMap { model, u in
            let input = int(u["inputTokens"])
            let cacheRead = min(int(u["cachedReadTokens"]), input)
            let uncached = input - cacheRead
            let cacheWrite = min(int(u["cacheCreationTokens"]), uncached)
            let output = int(u["outputTokens"]) // already includes reasoning
            if input == 0 && output == 0 { return nil }
            return UsageEvent(agent: .grok, model: model, date: date,
                              input: uncached - cacheWrite, output: output,
                              cacheRead: cacheRead, cacheWrite: cacheWrite,
                              key: eventId.map { "x:\(session):\($0):\(model)" })
        }
    }

    /// summary.json beside updates.jsonl names the session's model.
    private func defaultModel(_ ctx: ParseContext) -> String {
        if !ctx.loadedMeta {
            ctx.loadedMeta = true
            let summary = (ctx.path as NSString).deletingLastPathComponent + "/summary.json"
            if let data = FileManager.default.contents(atPath: summary),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                ctx.model = obj["current_model_id"] as? String
            }
        }
        return ctx.model ?? "unknown"
    }
}

// MARK: - GitHub Copilot CLI (~/.copilot/session-store.db)

final class CopilotSource: UsageSource {
    let agent = Agent.copilot
    private var events: [UsageEvent] = []
    private var lastId: Int64 = 0

    private var dbPath: String { (env("COPILOT_HOME") ?? home + "/.copilot") + "/session-store.db" }
    var roots: [String] { [dbPath] }

    func collect() -> [UsageEvent] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return events
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        let sql = """
            SELECT id, model, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, created_at
            FROM assistant_usage_events WHERE id > ? ORDER BY id
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return events }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, lastId)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let model = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "unknown"
            let input = Int(sqlite3_column_int64(stmt, 2))
            let output = Int(sqlite3_column_int64(stmt, 3))
            let cRead = Int(sqlite3_column_int64(stmt, 4))
            let cWrite = Int(sqlite3_column_int64(stmt, 5))
            let created = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            lastId = max(lastId, id)
            guard let date = ISODate.parse(created) else { continue }
            // input_tokens already includes the cached part.
            events.append(UsageEvent(agent: .copilot, model: model, date: date,
                                     input: max(0, input - cRead - cWrite), output: output,
                                     cacheRead: cRead, cacheWrite: cWrite, key: "cp:\(id)"))
        }
        premium = premiumThisMonth(db)
        return events
    }

    private var premium: Double?

    /// Premium requests this calendar month (UTC): one per prompt you typed, times the
    /// model's multiplier; follow-up tool calls and sub-agents are free.
    private func premiumThisMonth(_ db: OpaquePointer?) -> Double? {
        let sql = """
            SELECT SUM(m) FROM (
              SELECT MAX(COALESCE(request_multiplier, 1)) AS m FROM assistant_usage_events
              WHERE COALESCE(initiator, '') = '' AND created_at >= ?
              GROUP BY session_id, turn_index)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let start = Self.monthStart()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        let bound = f.string(from: start)
        sqlite3_bind_text(stmt, 1, bound, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_double(stmt, 0)
    }

    private static func monthStart(offset: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month], from: Date())
        let start = cal.date(from: comps)!
        return cal.date(byAdding: .month, value: offset, to: start)!
    }

    /// `allowance` 0 means unknown: show the count without a percentage.
    func quota(allowance: Int) -> AgentQuota? {
        guard let used = premium else { return nil }
        let n = used == used.rounded() ? "\(Int(used))" : String(format: "%.1f", used)
        let pct = allowance > 0 ? min(100, used / Double(allowance) * 100) : nil
        let detail = allowance > 0 ? "\(n) of \(allowance)" : "\(n) used"
        return AgentQuota(windows: [QuotaWindow(name: "Premium", percent: pct, detail: detail,
                                                resetsAt: Self.monthStart(offset: 1))],
                          asOf: Date(), note: nil)
    }
}
