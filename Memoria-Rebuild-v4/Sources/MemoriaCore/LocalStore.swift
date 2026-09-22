import Foundation

public actor LocalStore {
  private var state: LibraryState
  public let url: URL
  private let writer: (Data, URL) throws -> Void
  public init(
    url: URL,
    writer: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
  ) throws {
    self.url = url
    self.writer = writer
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: url.path) {
      let data = try Data(contentsOf: url)
      state = try Self.decodeBackup(data)
      var recovered = state
      for i in recovered.tasks.indices where recovered.tasks[i].phase.running {
        recovered.tasks[i].phase = .interrupted
      }
      if recovered.tasks.contains(where: { $0.phase == .interrupted }) {
        try writer(JSONEncoder().encode(recovered), url)
        state = recovered
      }
    } else {
      state = LibraryState()
    }
  }
  public func snapshot() -> LibraryState { state }
  private func transaction<T>(_ body: (inout LibraryState) throws -> T) throws -> T {
    var next = state
    let result = try body(&next)
    next.revision += 1
    let data = try JSONEncoder().encode(next)
    try writer(data, url)
    state = next
    return result
  }
  public func capture(_ entry: Entry, operationID: String) throws -> Entry {
    try transaction { s in
      if let id = s.operations[operationID], let old = s.entries.first(where: { $0.id == id }) {
        return old
      }
      guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        entry.text.count <= 100_000
      else { throw MemoriaError.invalid("请输入 1 至 100000 字的记录") }
      if let person = entry.personID, !s.people.contains(where: { $0.id == person }) {
        throw MemoriaError.stale
      }
      s.entries.insert(entry, at: 0)
      s.operations[operationID] = entry.id
      return entry
    }
  }
  public func savePerson(_ person: Person, expected: Int? = nil) throws {
    try transaction { s in
      guard !person.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        person.name.count <= 100, person.note.count <= 450, person.importantDate.count <= 200
      else { throw MemoriaError.invalid("请填写姓名；姓名最多100字，备注最多450字，日期最多200字") }
      let previous = s.people.first { $0.id == person.id }
      if let i = s.people.firstIndex(where: { $0.id == person.id }) {
        guard s.people[i].revision == expected else { throw MemoriaError.stale }
        var p = person
        p.revision += 1
        s.people[i] = p
      } else {
        s.people.append(person)
      }
      for (field, oldValue, newValue, label) in [
        ("note", previous?.note ?? "", person.note, "用户备注："),
        ("date", previous?.importantDate ?? "", person.importantDate, "重要日期："),
      ] where oldValue != newValue {
        let sourceIDs = Set(
          s.entries.filter { $0.profileField == person.id + ":" + field }.map(\.id))
        for i in s.memories.indices
        where sourceIDs.contains(s.memories[i].sourceID) && s.memories[i].status == .active {
          s.memories[i].status = .superseded
          s.memories[i].revision += 1
        }
        if !newValue.isEmpty {
          var source = Entry(text: label + newValue, personID: person.id)
          source.profileField = person.id + ":" + field
          let item = EntryItem(
            kind: .fact, subject: person.name, text: source.text, source_quote: source.text)
          var proposal = Proposal(source: source, item: item, personID: person.id)
          proposal.edited = true
          let memory = Memory(proposal: proposal)
          proposal.status = .confirmed
          proposal.memoryID = memory.id
          s.entries.insert(source, at: 0)
          s.proposals.append(proposal)
          s.memories.append(memory)
        }
      }
    }
  }
  public func deletePerson(_ id: String) throws {
    try transaction { s in
      s.people.removeAll { $0.id == id }
      for i in s.memories.indices where s.memories[i].personID == id {
        s.memories[i].status = .deleted
        s.memories[i].revision += 1
      }
      for i in s.proposals.indices where s.proposals[i].personID == id {
        s.proposals[i].status = .stale
        s.proposals[i].personID = nil
      }
      for i in s.entries.indices where s.entries[i].personID == id {
        s.entries[i].personID = nil
        Self.invalidate(s.entries[i].id, state: &s)
      }
      for i in s.outings.indices { s.outings[i].payload.participant_ids.removeAll { $0 == id } }
    }
  }
  private static func invalidate(_ id: String, state: inout LibraryState) {
    for i in state.tasks.indices
    where state.tasks[i].source_id == id && state.tasks[i].phase.running {
      state.tasks[i].phase = .cancelled
    }
    for i in state.proposals.indices
    where state.proposals[i].sourceID == id && state.proposals[i].status == .pending {
      state.proposals[i].status = .stale
    }
  }
  public func editEntry(_ id: String, revision: Int, text: String) throws {
    try transaction { s in
      guard let i = s.entries.firstIndex(where: { $0.id == id && !$0.deleted }),
        s.entries[i].revision == revision, !text.isEmpty
      else { throw MemoriaError.stale }
      s.entries[i].history.append(SourceVersion(revision: revision, text: s.entries[i].text))
      s.entries[i].text = text
      s.entries[i].revision += 1
      Self.invalidate(id, state: &s)
    }
  }
  public func deleteEntry(_ id: String) throws {
    try transaction { s in
      guard let i = s.entries.firstIndex(where: { $0.id == id }) else { throw MemoriaError.stale }
      s.entries[i].deleted = true
      s.entries[i].revision += 1
      Self.invalidate(id, state: &s)
      for i in s.memories.indices where s.memories[i].sourceID == id {
        s.memories[i].status = .deleted
        s.memories[i].revision += 1
      }
    }
  }
  public func begin(_ id: String) throws -> TaskState {
    try transaction { s in
      guard let source = s.entries.first(where: { $0.id == id && !$0.deleted }) else {
        throw MemoriaError.stale
      }
      Self.invalidate(id, state: &s)
      let task = TaskState(source: source)
      s.tasks.append(task)
      return task
    }
  }
  public func transition(_ task: TaskState, phase: Phase, error: String? = nil) throws {
    try transaction { s in
      guard let i = s.tasks.firstIndex(where: { $0.request_id == task.request_id }),
        s.tasks[i].phase.running,
        s.tasks.last(where: { $0.source_id == task.source_id })?.request_id == task.request_id,
        s.entries.contains(where: {
          $0.id == task.source_id && $0.revision == task.input_revision && !$0.deleted
        })
      else { throw MemoriaError.stale }
      s.tasks[i].phase = phase
      s.tasks[i].updated_at = Date()
      s.tasks[i].error = error
    }
  }
  public func install(
    _ analysis: EntryAnalysis, task: TaskState, decision: String? = nil, blocked: Bool = false
  ) throws {
    try install(
      ExtractionBatch(chunks: [ChunkReport(index: 0, text: "", analysis: analysis)]), task: task,
      decision: decision, blocked: blocked)
  }
  public func install(
    _ batch: ExtractionBatch, task: TaskState, decision: String? = nil, blocked: Bool = false
  ) throws {
    try transaction { s in
      guard let i = s.tasks.firstIndex(where: { $0.request_id == task.request_id }),
        s.tasks[i].phase.running,
        s.tasks.last(where: { $0.source_id == task.source_id })?.request_id == task.request_id,
        let source = s.entries.first(where: {
          $0.id == task.source_id && $0.revision == task.input_revision && !$0.deleted
        })
      else { throw MemoriaError.stale }
      let items = batch.analyses.flatMap(\.items)
      for item in items {
        if s.proposals.contains(where: {
          $0.sourceID == task.source_id && $0.sourceRevision == task.input_revision
            && $0.status == .confirmed && $0.item.source_quote == item.source_quote
        }) {
          continue
        }
        guard source.text.contains(item.source_quote) else { throw MemoriaError.invalid("来源校验失败") }
        let matches = s.people.filter {
          $0.name == item.subject || $0.aliases.contains(item.subject ?? "")
        }
        let person = matches.count == 1 ? matches[0].id : nil
        var issue = item.clarification
        if source.text.components(separatedBy: item.source_quote).count > 2 {
          issue = "原文有重复依据，请人工核对"
        }
        if item.subject != "我" && person == nil { issue = "请明确关联人物或选择自己" }
        if item.evidence_mode == .uncertain || item.evidence_mode == .hypothetical {
          issue = issue ?? "请保留推测或条件，并人工审阅"
        }
        if blocked { issue = "语义判断未通过，请人工核对并修改" }
        if s.activeMemories.contains(where: { $0.personID == person && $0.item.text == item.text })
        {
          issue = "已有相同记忆，请忽略或明确选择替换"
        } else if [.preference, .fact].contains(item.kind),
          s.activeMemories.contains(where: { $0.personID == person && $0.item.kind == item.kind })
        {
          issue = "已有相关资料，请核对是新增信息还是替换旧记忆"
        }
        s.proposals.append(Proposal(source: source, item: item, personID: person, issue: issue))
      }
      s.tasks[i].phase =
        items.isEmpty
        ? (batch.chunks.contains { $0.analysis == nil } ? .failed : .no_suggestions)
        : .awaiting_review
      s.tasks[i].chunks = batch.chunks
      s.tasks[i].error = batch.chunks.compactMap(\.error).first
      s.tasks[i].unprocessed = batch.remaining
      s.tasks[i].decisionStatus = decision
    }
  }
  public func manualProposal(
    sourceID: String, item: EntryItem, personID: String?, replacement: Memory? = nil
  ) throws -> Proposal {
    try transaction { s in
      guard let source = s.entries.first(where: { $0.id == sourceID && !$0.deleted }),
        source.text.contains(item.source_quote)
      else { throw MemoriaError.stale }
      Self.invalidate(sourceID, state: &s)
      var p = Proposal(source: source, item: item, personID: personID)
      p.edited = true
      p.replacementID = replacement?.id
      p.replacementRevision = replacement?.revision
      s.proposals.append(p)
      return p
    }
  }
  public func editProposal(_ proposal: Proposal, expected: Int) throws {
    try transaction { s in
      guard
        let i = s.proposals.firstIndex(where: { $0.id == proposal.id && $0.status == .pending }),
        s.proposals[i].revision == expected
      else { throw MemoriaError.stale }
      var p = proposal
      p.revision += 1
      p.edited = true
      p.issue = nil
      s.proposals[i] = p
    }
  }
  public func ignore(_ id: String, revision: Int) throws {
    try transaction { s in
      guard
        let i = s.proposals.firstIndex(where: {
          $0.id == id && $0.revision == revision && $0.status == .pending
        })
      else { throw MemoriaError.stale }
      s.proposals[i].status = .ignored
    }
  }
  @discardableResult public func confirm(_ id: String, revision: Int) throws -> String {
    try transaction { s in
      guard let i = s.proposals.firstIndex(where: { $0.id == id }),
        s.proposals[i].revision == revision
      else { throw MemoriaError.stale }
      let p = s.proposals[i]
      if p.status == .confirmed, let id = p.memoryID { return id }
      guard p.status == .pending, p.issue == nil, p.item.kind != .plan,
        !p.item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        p.item.text.count <= 500,
        let entry = s.entries.first(where: { $0.id == p.sourceID && !$0.deleted }),
        entry.revision == p.sourceRevision, entry.text.contains(p.item.source_quote),
        p.personID == nil
          ? p.item.subject == "我" : s.people.contains(where: { $0.id == p.personID })
      else { throw MemoriaError.invalid("请先修改建议，明确人物、依据或行程时间") }
      if let replacement = p.replacementID {
        guard
          let old = s.memories.firstIndex(where: { $0.id == replacement && $0.status == .active }),
          s.memories[old].revision == p.replacementRevision, s.memories[old].personID == p.personID
        else { throw MemoriaError.stale }
        s.memories[old].status = .superseded
        s.memories[old].revision += 1
      }
      let m = Memory(proposal: p)
      s.memories.append(m)
      s.proposals[i].status = .confirmed
      s.proposals[i].memoryID = m.id
      for j in s.tasks.indices where s.tasks[j].source_id == p.sourceID && s.tasks[j].phase.running
      { s.tasks[j].phase = .cancelled }
      return m.id
    }
  }
  public func revoke(_ memoryID: String, expected: Int, undo: Bool = false) throws {
    try transaction { s in
      guard let i = s.memories.firstIndex(where: { $0.id == memoryID && $0.status == .active }),
        s.memories[i].revision == expected
      else { throw MemoriaError.stale }
      if undo, let oldID = s.memories[i].replaces {
        guard let j = s.memories.firstIndex(where: { $0.id == oldID && $0.status == .superseded }),
          !s.memories.contains(where: {
            $0.id != memoryID && $0.replaces == oldID && $0.status == .active
          })
        else { throw MemoriaError.stale }
        s.memories[j].status = .active
        s.memories[j].revision += 1
      }
      s.memories[i].status = .revoked
      s.memories[i].revision += 1
    }
  }
  public func savePlan(_ plan: OutingPlan) throws {
    try transaction { s in
      guard !plan.stops.isEmpty, plan.stops.count <= 2,
        plan.budget == nil || (plan.budget!.isFinite && plan.budget! >= 0)
      else { throw MemoriaError.invalid("方案站点或预算无效") }
      if let old = s.plans.first(where: { $0.id == plan.id }) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard try encoder.encode(old) == encoder.encode(plan) else { throw MemoriaError.stale }
        return
      }
      s.plans.append(plan)
    }
  }
  @discardableResult public func execute(_ action: ActionDraft) throws -> String {
    try transaction { s in
      let key = "action:\(action.id):\(action.draft_revision)"
      if let id = s.operations[key] { return id }
      try Contract.action(action, state: s)
      let id: String
      if action.operation == "create", let payload = action.payload {
        let outing = Outing(payload: payload, plan: s.plans.first { $0.id == action.proposal_id })
        s.outings.append(outing)
        id = outing.id
      } else {
        guard let i = s.outings.firstIndex(where: { $0.id == action.target_id }) else {
          throw MemoriaError.stale
        }
        id = s.outings[i].id
        s.outings[i].history.append(s.outings[i].payload)
        s.outings[i].revision += 1
        if action.operation == "cancel" {
          s.outings[i].cancelled = true
        } else {
          s.outings[i].payload = action.payload!
          s.outings[i].plan = s.plans.first { $0.id == action.proposal_id }
        }
        s.outings[i].notificationStatus = "通知需要更新"
      }
      s.operations[key] = id
      return id
    }
  }
  public func notification(_ id: String, revision: Int, status: String) throws {
    try transaction { s in
      guard let i = s.outings.firstIndex(where: { $0.id == id && $0.revision == revision }) else {
        throw MemoriaError.stale
      }
      s.outings[i].notificationStatus = status
    }
  }
  public func export() throws -> Data { try JSONEncoder().encode(state) }
  public static func decodeBackup(_ data: Data) throws -> LibraryState {
    guard data.count <= 20_000_000 else { throw MemoriaError.invalid("备份超过 20 MB") }
    let s = try JSONDecoder().decode(LibraryState.self, from: data)
    guard s.format == 1 else { throw MemoriaError.invalid("不支持的备份版本") }
    func unique(_ values: [String]) -> Bool {
      Set(values).count == values.count && !values.contains("")
    }
    guard unique(s.entries.map(\.id)), unique(s.people.map(\.id)), unique(s.memories.map(\.id)),
      unique(s.proposals.map(\.id)), unique(s.outings.map(\.id)), unique(s.tasks.map(\.id)),
      unique(s.plans.map(\.id))
    else { throw MemoriaError.invalid("备份有重复标识") }
    let people = Set(s.people.map(\.id))
    for m in s.memories {
      guard let source = s.entries.first(where: { $0.id == m.sourceID }),
        let original = source.original(m.sourceRevision), original.contains(m.item.source_quote),
        m.revision > 0,
        m.status != .active || (m.personID == nil || people.contains(m.personID!))
      else { throw MemoriaError.invalid("备份记忆来源或人物已损坏") }
    }
    for p in s.proposals {
      guard
        s.entries.contains(where: {
          $0.id == p.sourceID
            && $0.original(p.sourceRevision)?.contains(p.item.source_quote) == true
        })
      else { throw MemoriaError.invalid("备份建议来源已损坏") }
    }
    for t in s.tasks {
      guard s.entries.contains(where: { $0.id == t.source_id }) else {
        throw MemoriaError.invalid("任务来源已损坏")
      }
    }
    for e in s.entries {
      guard e.revision > 0, e.history.allSatisfy({ $0.revision > 0 && $0.revision < e.revision }),
        unique(e.history.map { String($0.revision) }),
        e.personID == nil || people.contains(e.personID!)
      else { throw MemoriaError.invalid("原文版本或人物引用无效") }
    }
    for o in s.outings {
      guard o.revision > 0, !o.payload.title.isEmpty,
        Set(o.payload.participant_ids).isSubset(of: people),
        o.payload.estimated_total_cost == nil || o.payload.estimated_total_cost! >= 0
      else { throw MemoriaError.invalid("行程无效") }
      for date in [o.payload.start_at, o.payload.end_at, o.payload.remind_at].compactMap({ $0 }) {
        guard parseDate(date) != nil else { throw MemoriaError.invalid("行程日期无效") }
      }
      if let plan = o.plan {
        guard s.plans.contains(where: { $0.id == plan.id && $0.revision == plan.revision }) else {
          throw MemoriaError.invalid("方案引用无效")
        }
      }
    }
    for plan in s.plans {
      guard !plan.stops.isEmpty, plan.stops.count <= 2, unique(plan.stops.map(\.id)),
        plan.memoryIDs.allSatisfy({ id in s.memories.contains { $0.id == id } })
      else { throw MemoriaError.invalid("方案内容无效") }
      for stop in plan.stops {
        guard (-90...90).contains(stop.place.latitude), (-180...180).contains(stop.place.longitude),
          URL(string: stop.place.url)?.scheme == "https"
        else { throw MemoriaError.invalid("地点来源无效") }
      }
    }
    return s
  }
  public func restore(_ data: Data, expectedRevision: Int) throws {
    var next = try Self.decodeBackup(data)
    guard state.revision == expectedRevision else { throw MemoriaError.stale }
    let backup = url.deletingLastPathComponent().appendingPathComponent(
      "before-restore-\(uid()).json")
    try JSONEncoder().encode(state).write(to: backup, options: .atomic)
    for i in next.tasks.indices where next.tasks[i].phase.running {
      next.tasks[i].phase = .interrupted
    }
    next.revision = state.revision + 1
    try writer(JSONEncoder().encode(next), url)
    state = next
  }
}
