import CoreFoundation
import Foundation

public enum Contract {
  public static func schema(_ name: String) throws -> [String: Any] {
    guard let url = Bundle.module.url(forResource: name + ".schema", withExtension: "json") else {
      throw MemoriaError.invalid("找不到协议文件")
    }
    return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
  }
  public static func validate(
    _ value: Any, schema: [String: Any], path: String = "$", depth: Int = 0
  ) throws {
    guard depth < 30 else { throw MemoriaError.invalid("协议层级过深") }
    func reject(_ reason: String) throws { throw MemoriaError.invalid("\(path)：\(reason)") }
    let types = schema["type"] as? [String] ?? [schema["type"] as? String ?? ""]
    let isBool = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
    let type: String =
      value is NSNull
      ? "null"
      : value is String
        ? "string"
        : value is [String: Any]
          ? "object"
          : value is [Any] ? "array" : isBool ? "boolean" : value is NSNumber ? "number" : "unknown"
    let isInteger =
      (value as? NSNumber).map {
        !$0.doubleValue.isNaN && $0.doubleValue.rounded() == $0.doubleValue && !isBool
      } ?? false
    if !types.contains(type) && !(types.contains("integer") && isInteger) { try reject("类型错误") }
    if let options = schema["enum"] as? [String], let string = value as? String,
      !options.contains(string)
    {
      try reject("不支持的枚举")
    }
    if let string = value as? String {
      let count = string.unicodeScalars.count
      if let min = schema["minLength"] as? Int, count < min { try reject("内容为空") }
      if let max = schema["maxLength"] as? Int, count > max { try reject("内容过长") }
    }
    if let number = value as? NSNumber, !isBool, let min = schema["minimum"] as? Double,
      number.doubleValue < min
    {
      try reject("数值超出范围")
    }
    if let object = value as? [String: Any] {
      let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
      if schema["additionalProperties"] as? Bool == false,
        !Set(object.keys).isSubset(of: Set(properties.keys))
      {
        try reject("含未知字段")
      }
      if let required = schema["required"] as? [String],
        !Set(required).isSubset(of: Set(object.keys))
      {
        try reject("缺少必要字段")
      }
      for (key, item) in object {
        if let s = properties[key] {
          try validate(item, schema: s, path: path + "." + key, depth: depth + 1)
        }
      }
    }
    if let array = value as? [Any] {
      if let max = schema["maxItems"] as? Int, array.count > max { try reject("条数过多") }
      if let min = schema["minItems"] as? Int, array.count < min { try reject("条数不足") }
      if schema["uniqueItems"] as? Bool == true {
        let keys = try array.map {
          try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys])
        }
        if Set(keys).count != keys.count { try reject("存在重复项") }
      }
      if let s = schema["items"] as? [String: Any] {
        for (i, item) in array.enumerated() {
          try validate(item, schema: s, path: "\(path)[\(i)]", depth: depth + 1)
        }
      }
    }
  }
  public static func decode<T: Decodable>(_ type: T.Type, text: String, schema name: String) throws
    -> T
  {
    guard let data = text.data(using: .utf8), data.count < 1_000_000 else {
      throw MemoriaError.invalid("响应过长")
    }
    try validate(JSONSerialization.jsonObject(with: data), schema: schema(name))
    return try JSONDecoder().decode(type, from: data)
  }
  public static func analysis(_ text: String, source: String) throws -> EntryAnalysis {
    let result = try decode(EntryAnalysis.self, text: text, schema: "entry-analysis.v2")
    for item in result.items {
      guard source.contains(item.source_quote),
        !item.source_quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw MemoriaError.invalid("建议引用与原文不一致") }
      // Repeated quotations require explicit manual review, not guessed character offsets.
      if source.components(separatedBy: item.source_quote).count > 2 {
        throw MemoriaError.invalid("原文有重复引文，请手动选择依据")
      }
    }
    guard result.unprocessed_quotes.allSatisfy(source.contains) else {
      throw MemoriaError.invalid("未处理片段不属于原文")
    }
    return result
  }
  public static func recall(_ text: String, candidates: [Memory]) throws -> RecallAnswer {
    let answer = try decode(RecallAnswer.self, text: text, schema: "recall-answer.v1")
    let allowed = Set(candidates.map(\.id))
    for statement in answer.statements {
      guard Set(statement.source_ids).isSubset(of: allowed), !statement.source_ids.isEmpty else {
        throw MemoriaError.invalid("回答引用无效")
      }
    }
    for suggestion in answer.suggestions {
      guard Set(suggestion.source_ids).isSubset(of: allowed),
        suggestion.basis == "general"
          ? suggestion.source_ids.isEmpty : !suggestion.source_ids.isEmpty
      else { throw MemoriaError.invalid("建议缺少有效依据") }
    }
    if answer.status == "not_found" && !answer.statements.isEmpty {
      throw MemoriaError.invalid("无资料回答含事实")
    }
    if (answer.clarification != nil) != (answer.next_step == "clarify") {
      throw MemoriaError.invalid("澄清状态不一致")
    }
    if answer.status == "needs_clarification"
      && (answer.clarification == nil || !answer.statements.isEmpty
        || answer.suggestions.contains { $0.basis == "personalized" })
    {
      throw MemoriaError.invalid("人物未明确时不能回答事实")
    }
    return answer
  }
  // Codable omits nil properties; local domain serialization explicitly fills nullable
  // required keys. Remote/model responses never pass through this normalization.
  public static func encodeDomain<T: Encodable>(_ value: T, schema name: String) throws -> Data {
    let contract = try schema(name)
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    func fill(_ value: Any, _ schema: [String: Any]) -> Any {
      if var object = value as? [String: Any],
        let props = schema["properties"] as? [String: [String: Any]]
      {
        for (key, child) in props {
          if let existing = object[key] {
            object[key] = fill(existing, child)
          } else if (child["type"] as? [String])?.contains("null") == true {
            object[key] = NSNull()
          }
        }
        return object
      }
      if let list = value as? [Any], let item = schema["items"] as? [String: Any] {
        return list.map { fill($0, item) }
      }
      return value
    }
    let normalized = fill(encoded, contract)
    try validate(normalized, schema: contract)
    return try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys])
  }
  public static func action(_ action: ActionDraft, state: LibraryState, now: Date = Date()) throws {
    _ = try encodeDomain(action, schema: "action-draft.v1")
    guard action.schema_version == "1.0", action.draft_revision > 0 else {
      throw MemoriaError.invalid("动作版本不支持")
    }
    if let sourceID = action.source_entry_id {
      guard let e = state.entries.first(where: { $0.id == sourceID && !$0.deleted }),
        e.revision == action.source_revision, let quote = action.evidence_quote, !quote.isEmpty,
        e.text.contains(quote)
      else { throw MemoriaError.stale }
    } else if action.source_revision != nil || action.evidence_quote != nil {
      throw MemoriaError.invalid("来源字段不一致")
    }
    switch action.operation {
    case "create":
      guard action.target_id == nil, action.expected_target_revision == nil, action.payload != nil
      else { throw MemoriaError.invalid("新增动作无效") }
    case "update", "cancel":
      guard let target = state.outings.first(where: { $0.id == action.target_id && !$0.cancelled }),
        target.revision == action.expected_target_revision
      else { throw MemoriaError.stale }
    default: throw MemoriaError.invalid("未知行程操作")
    }
    if action.operation == "cancel" {
      guard action.payload == nil, action.proposal_id == nil, action.proposal_revision == nil else {
        throw MemoriaError.invalid("取消不能携带新方案")
      }
      return
    }
    guard let p = action.payload, !p.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      p.title.count <= 200, let tz = TimeZone(identifier: p.time_zone),
      Set(p.participant_ids).isSubset(of: Set(state.people.map(\.id))),
      Set(p.participant_ids).count == p.participant_ids.count
    else { throw MemoriaError.invalid("请检查标题、时区和参与者") }
    if let cost = p.estimated_total_cost, !cost.isFinite || cost < 0 {
      throw MemoriaError.invalid("费用需为有限的非负数")
    }
    for value in [p.start_at, p.end_at, p.remind_at].compactMap({ $0 }) {
      guard let date = parseDate(value) else { throw MemoriaError.invalid("日期必须包含时区") }
      // UTC is a valid canonical instant; explicit non-UTC offsets must match declared zone.
      if !value.hasSuffix("Z") {
        let suffix = String(value.suffix(6))
        let parts = suffix.dropFirst().split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
          suffix.first == "+" || suffix.first == "-",
          (h * 3600 + m * 60) * (suffix.first == "-" ? -1 : 1) == tz.secondsFromGMT(for: date)
        else { throw MemoriaError.invalid("时间偏移与时区不一致") }
      }
    }
    if let start = p.start_at.flatMap(parseDate), let end = p.end_at.flatMap(parseDate),
      end <= start
    {
      throw MemoriaError.invalid("结束时间必须晚于开始时间")
    }
    if let reminder = p.remind_at.flatMap(parseDate) {
      guard p.start_at != nil, p.end_at != nil, reminder > now,
        reminder <= p.start_at.flatMap(parseDate)!
      else { throw MemoriaError.invalid("提醒必须在未来且不晚于活动开始") }
    }
    if let planID = action.proposal_id {
      guard
        let plan = state.plans.first(where: {
          $0.id == planID && $0.revision == action.proposal_revision
        }), !plan.stops.isEmpty,
        plan.memoryIDs.allSatisfy({ id in
          state.activeMemories.contains {
            $0.id == id && ($0.personID == nil || p.participant_ids.contains($0.personID!))
          }
        })
      else { throw MemoriaError.stale }
      guard p.location_name == plan.stops.first?.place.name else {
        throw MemoriaError.invalid("摘要地点与完整方案不一致，请先修改方案地点")
      }
      if let budget = plan.budget, let cost = p.estimated_total_cost, cost > budget {
        throw MemoriaError.invalid("预计费用超过总预算")
      }
    } else if action.proposal_revision != nil {
      throw MemoriaError.invalid("缺少方案引用")
    }
  }
}
