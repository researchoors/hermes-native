import Foundation

/// Centaur control-plane workflow surfaces (services/api-rs):
/// `GET /api/workflows/runs`, `GET /api/workflows/runs/{id}`,
/// `POST /api/workflows/runs/{id}/cancel`, `GET /api/workflows/schedules`.
/// The Centaur analogue of Hermes cron: schedules are the standing
/// definitions, runs the execution history.
struct CentaurWorkflowRun: Decodable, Identifiable {
    let runID: String
    let taskID: String
    let workflowName: String
    let status: String
    let input: AnyCodable?
    let result: AnyCodable?
    let failure: AnyCodable?
    let attempts: Int
    let createdAt: Date?
    let updatedAt: Date?

    var id: String { runID }

    /// Terminal states can't be cancelled.
    var isActive: Bool {
        switch status.lowercased() {
        case "completed", "failed", "cancelled", "canceled": return false
        default: return true
        }
    }

    /// Human summary of a failure payload, if any.
    var failureSummary: String? {
        guard let failure else { return nil }
        if let s = failure.stringValue { return s }
        if let d = failure.dictionaryValue {
            return d["message"]?.stringValue ?? d["error"]?.stringValue ?? failure.displayString
        }
        return failure.displayString
    }

    private enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case taskID = "task_id"
        case workflowName = "workflow_name"
        case status, input, result, failure, attempts
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runID = try c.decode(String.self, forKey: .runID)
        taskID = try c.decodeIfPresent(String.self, forKey: .taskID) ?? ""
        workflowName = try c.decodeIfPresent(String.self, forKey: .workflowName) ?? "workflow"
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        input = try c.decodeIfPresent(AnyCodable.self, forKey: .input)
        result = try c.decodeIfPresent(AnyCodable.self, forKey: .result)
        failure = try c.decodeIfPresent(AnyCodable.self, forKey: .failure)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        // RFC 3339 timestamps.
        createdAt = (try? c.decodeIfPresent(String.self, forKey: .createdAt)).flatMap(Self.parseDate)
        updatedAt = (try? c.decodeIfPresent(String.self, forKey: .updatedAt)).flatMap(Self.parseDate)
    }

    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        // Fractional seconds first (the server emits them), then plain.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: s) { return date }
        return ISO8601DateFormatter().date(from: s)
    }
}

struct CentaurWorkflowSchedule: Decodable, Identifiable {
    let scheduleID: String
    let workflowName: String
    let kind: AnyCodable?
    let timezone: String
    let enabled: Bool

    var id: String { scheduleID }

    /// Display form of the schedule kind: {"cron": {"expr": "0 9 * * *"}} or
    /// {"interval": {"secs": 3600}} — flattened to a short label.
    var kindLabel: String {
        guard let d = kind?.dictionaryValue else {
            return kind?.stringValue ?? "manual"
        }
        if let cron = d["cron"] {
            return cron.dictionaryValue?["expr"]?.stringValue.map { "cron: \($0)" }
                ?? "cron"
        }
        if let interval = d["interval"] {
            if let secs = interval.dictionaryValue?["secs"]?.intValue {
                return "every \(Duration.seconds(secs).formatted(.units(width: .narrow)))"
            }
            return "interval"
        }
        return d.keys.sorted().joined(separator: ", ")
    }

    private enum CodingKeys: String, CodingKey {
        case scheduleID = "schedule_id"
        case workflowName = "workflow_name"
        case kind, timezone, enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scheduleID = try c.decode(String.self, forKey: .scheduleID)
        workflowName = try c.decodeIfPresent(String.self, forKey: .workflowName) ?? "workflow"
        kind = try c.decodeIfPresent(AnyCodable.self, forKey: .kind)
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}
