import Foundation

public func uid() -> String { UUID().uuidString }
public enum MemoriaError: Error, LocalizedError {
  case invalid(String)
  case stale, configuration, missingKey
  case http(Int)
  case refused, truncated, empty
  public var errorDescription: String? {
    switch self {
    case .invalid(let message): return message
    case .stale: return "内容已经变化，请查看最新版本后再操作。"
    case .configuration: return "请先在设置中配置模型并允许云端处理。"
    case .missingKey: return "尚未配置密钥，请到设置中保存。"
    case .http(let code):
      switch code {
      case 401, 403: return "密钥未通过验证，请检查设置。"
      case 429: return "服务限流，请稍后重试。"
      case 400, 404: return "服务不支持当前模型或参数，请检查配置。"
      default: return "服务请求失败（HTTP \(code)）。"
      }
    case .refused: return "模型未提供可用内容，原文仍然保留。"
    case .truncated: return "模型响应被截断，请缩短记录后重试。"
    case .empty: return "服务返回空内容，请稍后重试。"
    }
  }
}
public enum Kind: String, Codable, CaseIterable {
  case fact, preference, experience, goal, plan, note
}
public enum Evidence: String, Codable { case direct, reported, uncertain, hypothetical }
public struct EntryItem: Codable, Equatable {
  public var kind: Kind
  public var subject: String?
  public var text: String
  public var source_quote: String
  public var evidence_mode: Evidence
  public var time_text: String?
  public var scope_text: String?
  public var clarification: String?
  public init(
    kind: Kind = .preference, subject: String? = "我", text: String, source_quote: String,
    evidence_mode: Evidence = .direct, time_text: String? = nil, scope_text: String? = nil,
    clarification: String? = nil
  ) {
    self.kind = kind
    self.subject = subject
    self.text = text
    self.source_quote = source_quote
    self.evidence_mode = evidence_mode
    self.time_text = time_text
    self.scope_text = scope_text
    self.clarification = clarification
  }
}
public struct EntryAnalysis: Codable {
  public var schema_version: String
  public var items: [EntryItem]
  public var unprocessed_quotes: [String]
  public init(schema_version: String = "2.0", items: [EntryItem], unprocessed_quotes: [String] = [])
  {
    self.schema_version = schema_version
    self.items = items
    self.unprocessed_quotes = unprocessed_quotes
  }
}
public struct Person: Codable, Identifiable, Equatable {
  public var id = uid()
  public var revision = 1
  public var name: String
  public var note = ""
  public var aliases: [String] = []
  public var importantDate = ""
  public init(name: String, note: String = "") {
    self.name = name
    self.note = note
  }
}
public struct SourceVersion: Codable, Equatable {
  public var revision: Int
  public var text: String
}
public struct Entry: Codable, Identifiable {
  public var id = uid()
  public var revision = 1
  public var text: String
  public var created = Date()
  public var timezone = TimeZone.current.identifier
  public var personID: String?
  public var outingID: String?
  public var profileField: String?
  public var demo = false
  public var deleted = false
  public var history: [SourceVersion] = []
  public init(text: String, personID: String? = nil, outingID: String? = nil, demo: Bool = false) {
    self.text = text
    self.personID = personID
    self.outingID = outingID
    self.demo = demo
  }
  public func original(_ revision: Int) -> String? {
    self.revision == revision ? text : history.first { $0.revision == revision }?.text
  }
}
public enum Phase: String, Codable {
  case queued, waiting_model, validating, awaiting_review, no_suggestions, failed, cancelled,
    interrupted
  public var running: Bool { [.queued, .waiting_model, .validating].contains(self) }
  public var label: String {
    switch self {
    case .queued: return "已保存，等待整理"
    case .waiting_model: return "已保存，正在整理"
    case .validating: return "正在检查建议内容"
    case .awaiting_review: return "建议待确认"
    case .no_suggestions: return "原文已保存"
    case .failed: return "原文已保存，整理未完成"
    case .cancelled: return "已停止整理，原文仍保留"
    case .interrupted: return "上次整理中断，可以重试"
    }
  }
}
public struct TaskState: Codable, Identifiable {
  public var id = uid()
  public var source_id: String
  public var input_revision: Int
  public var request_id = uid()
  public var phase: Phase = .queued
  public var started_at = Date()
  public var updated_at = Date()
  public var error: String?
  public var unprocessed: [String] = []
  public var decisionStatus: String?
  public var chunks: [ChunkReport]?
  public init(source: Entry) {
    source_id = source.id
    input_revision = source.revision
  }
}
public enum ProposalStatus: String, Codable { case pending, confirmed, ignored, stale }
public struct Proposal: Codable, Identifiable {
  public var id = uid()
  public var revision = 1
  public var sourceID: String
  public var sourceRevision: Int
  public var item: EntryItem
  public var personID: String?
  public var status: ProposalStatus = .pending
  public var memoryID: String?
  public var edited = false
  public var replacementID: String?
  public var replacementRevision: Int?
  public var issue: String?
  public init(source: Entry, item: EntryItem, personID: String?, issue: String? = nil) {
    sourceID = source.id
    sourceRevision = source.revision
    self.item = item
    self.personID = personID
    self.issue = issue
  }
}
public enum MemoryStatus: String, Codable { case active, superseded, revoked, deleted }
public struct Memory: Codable, Identifiable {
  public var id = uid()
  public var revision = 1
  public var item: EntryItem
  public var personID: String?
  public var sourceID: String
  public var sourceRevision: Int
  public var created = Date()
  public var status: MemoryStatus = .active
  public var userEdited = false
  public var replaces: String?
  public var expiresAt: Date?
  public init(proposal: Proposal) {
    item = proposal.item
    personID = proposal.personID
    sourceID = proposal.sourceID
    sourceRevision = proposal.sourceRevision
    userEdited = proposal.edited
    replaces = proposal.replacementID
  }
}
public struct RecallStatement: Codable {
  public var text: String
  public var statement_type: String
  public var source_ids: [String]
}
public struct RecallSuggestion: Codable {
  public var text: String
  public var basis: String
  public var source_ids: [String]
}
public struct RecallAnswer: Codable {
  public var schema_version = "1.0"
  public var status = "not_found"
  public var statements: [RecallStatement] = []
  public var suggestions: [RecallSuggestion] = []
  public var missing_info: [String] = []
  public var clarification: String?
  public var next_step = "none"
  public init() {}
}
public struct OutingPayload: Codable, Equatable {
  public var title: String
  public var start_at: String?
  public var end_at: String?
  public var time_zone: String
  public var location_name: String?
  public var participant_ids: [String]
  public var estimated_total_cost: Double?
  public var notes: String?
  public var remind_at: String?
  public init(
    title: String, start: Date? = nil, end: Date? = nil, location: String? = nil,
    people: [String] = [], cost: Double? = nil, notes: String? = nil, reminder: Date? = nil
  ) {
    self.title = title
    start_at = start.map(iso)
    end_at = end.map(iso)
    time_zone = TimeZone.current.identifier
    location_name = location
    participant_ids = people
    estimated_total_cost = cost
    self.notes = notes
    remind_at = reminder.map(iso)
  }
}
public struct ActionDraft: Codable, Identifiable {
  public var schema_version = "1.0"
  public var draft_id = uid()
  public var draft_revision = 1
  public var source_entry_id: String?
  public var source_revision: Int?
  public var operation = "create"
  public var target_id: String?
  public var expected_target_revision: Int?
  public var evidence_quote: String?
  public var proposal_id: String?
  public var proposal_revision: Int?
  public var payload: OutingPayload?
  public var id: String { draft_id }
  public init(payload: OutingPayload?) { self.payload = payload }
}
public struct Place: Codable, Identifiable, Equatable {
  public var id = uid()
  public var name: String
  public var address: String
  public var latitude: Double
  public var longitude: Double
  public var url: String
  public var fetchedAt = Date()
  public init(name: String, address: String, latitude: Double, longitude: Double, url: String) {
    self.name = name
    self.address = address
    self.latitude = latitude
    self.longitude = longitude
    self.url = url
  }
}
public struct Stop: Codable, Identifiable {
  public var id = uid()
  public var place: Place
  public var time: String?
  public var cost: Double?
  public init(place: Place) { self.place = place }
}
public struct OutingPlan: Codable, Identifiable {
  public var id = uid()
  public var revision = 1
  public var stops: [Stop]
  public var memoryIDs: [String]
  public var budget: Double?
  public var budgetBasis = "所有参与者总额"
  public var notes: String
  public var demo = false
  public init(stops: [Stop], memoryIDs: [String], budget: Double?, notes: String) {
    self.stops = stops
    self.memoryIDs = memoryIDs
    self.budget = budget
    self.notes = notes
  }
}
public struct Outing: Codable, Identifiable {
  public var id = uid()
  public var revision = 1
  public var payload: OutingPayload
  public var plan: OutingPlan?
  public var cancelled = false
  public var notificationStatus = "未安排通知"
  public var history: [OutingPayload] = []
  public init(payload: OutingPayload, plan: OutingPlan? = nil) {
    self.payload = payload
    self.plan = plan
  }
}
public struct LibraryState: Codable {
  public var format = 1
  public var revision = 0
  public var entries: [Entry] = []
  public var people: [Person] = []
  public var memories: [Memory] = []
  public var proposals: [Proposal] = []
  public var tasks: [TaskState] = []
  public var outings: [Outing] = []
  public var plans: [OutingPlan] = []
  public var operations: [String: String] = [:]
  public init() {}
  public var activeMemories: [Memory] {
    memories.filter { m in
      m.status == .active && (m.expiresAt == nil || m.expiresAt! > Date())
        && entries.contains { $0.id == m.sourceID && !$0.deleted }
    }
  }
}
public func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
public func parseDate(_ string: String) -> Date? { ISO8601DateFormatter().date(from: string) }
