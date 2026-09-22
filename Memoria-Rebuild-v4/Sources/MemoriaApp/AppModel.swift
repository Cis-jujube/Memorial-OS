import AppKit
import MemoriaCore
import SwiftUI

@MainActor final class AppModel: ObservableObject {
  @Published var state = LibraryState()
  @Published var page = "记录"
  @Published var draft = ""
  @Published var capturePerson = ""
  @Published var captureOuting: String?
  @Published var query = ""
  @Published var queryPerson = ""
  @Published var recall: RecallResult?
  @Published var queryBusy = false
  @Published var saving = false
  @Published var notice = ""
  @Published var error: String?
  @Published var config = ProviderConfig()
  @Published var sourcePreview: Entry?
  @Published var demo = false
  @Published var configStatus = "能力尚未验证"
  @Published var toolBusy = false
  @Published var toolReceipts: [ToolReceipt] = []
  @Published var places: [Place] = []
  @Published var plan: OutingPlan?
  private var queryTask: Task<Void, Never>?
  private var queryID = uid()
  private var workers: [String: Task<Void, Never>] = [:]
  private var queue: [(Entry, TaskState, Bool, ProviderConfig)] = []
  private var toolTask: Task<Void, Never>?
  private var toolID = uid()
  let store: LocalStore?
  let directory: URL
  private let lock = SingleInstance()
  init() {
    directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Memoria-Rebuild-v4", isDirectory: true)
    do {
      try lock.acquire(directory: directory)
      store = try LocalStore(url: directory.appendingPathComponent("store.json"))
    } catch {
      store = nil
      self.error = error.localizedDescription
    }
    if let data = UserDefaults.standard.data(forKey: "providerConfig"),
      let c = try? JSONDecoder().decode(ProviderConfig.self, from: data)
    {
      config = c
    }
    Task { await refresh() }
  }
  func refresh() async {
    guard let store else { return }
    state = await store.snapshot()
    if let result = recall, result.revision != state.revision {
      recall = RecallService.query(query, personID: queryPerson.nilIfEmpty, state: state)
    }
  }
  func perform(_ operation: @escaping (LocalStore) async throws -> Void) {
    guard let store else {
      error = "数据没有成功打开，不能写入。请保留原文件并查看错误。"
      return
    }
    Task {
      do {
        try await operation(store)
        await refresh()
      } catch { self.error = error.localizedDescription }
    }
  }
  func capture(organize: Bool) {
    guard let store, !saving, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }
    let text = draft
    let source = Entry(
      text: text, personID: capturePerson.nilIfEmpty, outingID: captureOuting, demo: demo)
    saving = true
    Task {
      defer { saving = false }
      do {
        let entry = try await store.capture(source, operationID: uid())
        if draft == text {
          draft = ""
          captureOuting = nil
        }
        await refresh()
        notice = "原文已保存"
        if organize { await enqueue(entry) }
      } catch { self.error = "保存失败：\(error.localizedDescription)" }
    }
  }
  func enqueue(_ entry: Entry) async {
    guard let store else { return }
    workers[entry.id]?.cancel()
    queue.removeAll { $0.0.id == entry.id }
    do {
      let task = try await store.begin(entry.id)
      queue.append((entry, task, demo, config))
      await refresh()
      pump()
    } catch { self.error = error.localizedDescription }
  }
  private func pump() {
    guard workers.isEmpty, !queue.isEmpty, let store else { return }
    let (entry, task, demoMode, settings) = queue.removeFirst()
    workers[entry.id] = Task {
      defer {
        workers[entry.id] = nil
        pump()
      }
      do {
        try Task.checkCancellation()
        try await store.transition(task, phase: .waiting_model)
        await refresh()
        let analysis: EntryAnalysis
        var batch: ExtractionBatch?
        var decision: String?
        var blocked = false
        if demoMode {
          guard entry.text == "小林喜欢安静的展览。下周想约她出去，但时间还没定。" else {
            throw MemoriaError.invalid("演示仅支持预设合成样例；其他记录请手动整理或配置模型。")
          }
          let text = """
            {"schema_version":"2.0","items":[{"kind":"preference","subject":"小林","text":"喜欢安静的展览","source_quote":"小林喜欢安静的展览","evidence_mode":"direct","time_text":null,"scope_text":null,"clarification":null},{"kind":"plan","subject":"我","text":"下周想约小林出去，时间未定","source_quote":"下周想约她出去，但时间还没定","evidence_mode":"direct","time_text":"下周","scope_text":"时间还没定","clarification":"你想安排在哪一天？"}],"unprocessed_quotes":[]}
            """
          analysis = try Contract.analysis(text, source: entry.text)
          decision = "演示 fixture，未调用模型"
        } else {
          guard settings.cloudConsent else { throw MemoriaError.configuration }
          let key = try Credentials.read(settings.provider.rawValue)
          let client = ModelClient(config: settings, key: key)
          let people = state.people
          let cached =
            state.tasks.reversed().first {
              $0.source_id == entry.id && $0.input_revision == entry.revision && $0.chunks != nil
            }?.chunks ?? []
          let extracted = try await client.extractBatch(entry, people: people, cached: cached)
          batch = extracted
          analysis = EntryAnalysis(
            schema_version: "2.0", items: Array(extracted.analyses.flatMap(\.items).prefix(8)),
            unprocessed_quotes: extracted.remaining)
          if settings.jevEnabled && !analysis.items.isEmpty {
            do {
              let jev = JevAdapter(key: try Credentials.read("Jev"), model: settings.jevModel)
              let relevant = state.activeMemories.filter { m in
                analysis.items.contains { $0.subject == m.item.subject }
              }
              let result = try await jev.evaluate(
                source: entry, items: analysis.items, memories: relevant)
              blocked = !result.supported || (batch?.analyses.flatMap(\.items).count ?? 0) > 8
              decision = "Jev \(result.model)：" + (blocked ? "需要人工审阅" : "判断完成，仍需确认")
            } catch is CancellationError { throw CancellationError() } catch {
              decision = "Jev 未完成：\(error.localizedDescription)；保留人工确认"
              blocked = true
            }
          }
        }
        try Task.checkCancellation()
        try await store.transition(task, phase: .validating)
        if let batch {
          try await store.install(batch, task: task, decision: decision, blocked: blocked)
        } else {
          try await store.install(analysis, task: task, decision: decision, blocked: blocked)
        }
        await refresh()
      } catch {
        let cancelled = Task.isCancelled || error is CancellationError
        do {
          try await store.transition(
            task, phase: cancelled ? .cancelled : .failed,
            error: cancelled ? nil : error.localizedDescription)
        } catch MemoriaError.stale {
          // A newer revision already invalidated this attempt.
        } catch { self.error = "无法保存整理状态：\(error.localizedDescription)" }
        await refresh()
      }
    }
  }
  func cancel(_ entry: Entry) {
    workers[entry.id]?.cancel()
    queue.removeAll { $0.0.id == entry.id }
    if let task = state.tasks.last(where: { $0.source_id == entry.id && $0.phase.running }) {
      perform { try await $0.transition(task, phase: .cancelled) }
    }
  }
  func ask(synthesize: Bool = false) {
    queryTask?.cancel()
    queryID = uid()
    let id = queryID
    let local = RecallService.query(query, personID: queryPerson.nilIfEmpty, state: state)
    recall = local
    queryBusy = false
    guard synthesize, local.answer.status != "needs_clarification" else { return }
    queryBusy = true
    let question = query
    queryTask = Task {
      defer { if queryID == id { queryBusy = false } }
      do {
        guard config.cloudConsent else { throw MemoriaError.configuration }
        let client = ModelClient(
          config: config, key: try Credentials.read(config.provider.rawValue))
        let answer = try await RecallService.synthesized(local, question: question, client: client)
        try Task.checkCancellation()
        guard id == queryID, state.revision == local.revision else { return }
        var result = local
        result.answer = answer
        recall = result
      } catch { if id == queryID && !Task.isCancelled { self.error = error.localizedDescription } }
    }
  }
  func invalidateQuery() {
    queryTask?.cancel()
    queryID = uid()
    queryBusy = false
    recall = nil
  }
  func showSource(_ memory: Memory) {
    guard var source = state.entries.first(where: { $0.id == memory.sourceID }) else { return }
    source.text = source.original(memory.sourceRevision) ?? source.text
    sourcePreview = source
  }
  func saveConfig(key: String, jevKey: String, braveKey: String) {
    do {
      if !key.isEmpty { try Credentials.save(config.provider.rawValue, value: key) }
      if !jevKey.isEmpty { try Credentials.save("Jev", value: jevKey) }
      if !braveKey.isEmpty { try Credentials.save("Brave", value: braveKey) }
      UserDefaults.standard.set(try JSONEncoder().encode(config), forKey: "providerConfig")
      notice = "配置已保存；密钥只存入新 App 的钥匙串"
    } catch { self.error = error.localizedDescription }
  }
  func testConnection() {
    Task {
      configStatus = "正在测试文本连接…"
      do {
        guard config.cloudConsent else { throw MemoriaError.configuration }
        let client = ModelClient(
          config: config, key: try Credentials.read(config.provider.rawValue))
        _ = try await client.complete(system: "只回答OK", messages: [client.user("连接测试，不含私人内容")])
        configStatus = "文本连接通过；结构化与工具能力仍未验证"
      } catch { configStatus = error.localizedDescription }
    }
  }
  func loadDemo() {
    demo = true
    perform { store in
      let current = await store.snapshot()
      if !current.people.contains(where: { $0.name == "小林" }) {
        try await store.savePerson(Person(name: "小林", note: "虚构演示人物"))
      }
    }
    draft = "小林喜欢安静的展览。下周想约她出去，但时间还没定。"
    page = "记录"
  }
  func lookup(publicQuery: String, date: Date, budget: Double?, personID: String?, agent: Bool) {
    toolTask?.cancel()
    toolID = uid()
    let id = toolID
    toolBusy = true
    toolReceipts = []
    places = []
    plan = nil
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    let day = formatter.string(from: date)
    let memories = Array(state.activeMemories.filter { $0.personID == personID }.prefix(12))
    toolTask = Task {
      defer { if toolID == id { toolBusy = false } }
      do {
        let service = ToolService(
          publicQuery: publicQuery, date: day, budget: budget, memories: memories,
          braveKey: try Credentials.read("Brave"))
        if agent {
          guard config.cloudConsent else { throw MemoriaError.configuration }
          let client = ModelClient(
            config: config, key: try Credentials.read(config.provider.rawValue))
          let result = try await AgentRunner.run(
            client: client, tools: service,
            prompt:
              "日期\(day)，区域与活动关键词\(publicQuery)，总预算人民币\(budget.map { String($0) } ?? "未知")。请提出方案。")
          guard toolID == id, !Task.isCancelled else { return }
          plan = result
        } else {
          for name in ["search_places", "get_weather", "search_web"] {
            try Task.checkCancellation()
            _ = await service.execute(ToolCall(id: uid(), name: name, arguments: [:]))
            guard toolID == id, !Task.isCancelled else { return }
            toolReceipts = await service.receipts
            places = await service.places
          }
        }
        guard toolID == id, !Task.isCancelled else { return }
        toolReceipts = await service.receipts
        places = await service.places
      } catch { if toolID == id && !Task.isCancelled { self.error = error.localizedDescription } }
    }
  }
  func cancelTools() {
    toolTask?.cancel()
    toolID = uid()
    toolBusy = false
    notice = "查询已取消，已有行程未受影响"
  }
  func saveOuting(_ action: ActionDraft, plan: OutingPlan?) {
    perform { store in
      if let plan { try await store.savePlan(plan) }
      let id = try await store.execute(action)
      if let outing = await store.snapshot().outings.first(where: { $0.id == id }) {
        let status = await Notifications.sync(outing)
        try await store.notification(id, revision: outing.revision, status: status)
      }
    }
  }
  func exportBackup() {
    guard let store else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Memoria-backup.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      do {
        try await store.export().write(to: url, options: .atomic)
        notice = "备份已导出，不含密钥"
      } catch { self.error = error.localizedDescription }
    }
  }
  func restoreBackup() {
    guard let store else { return }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let data = try Data(contentsOf: url)
      let preview = try LocalStore.decodeBackup(data)
      let revision = state.revision
      let alert = NSAlert()
      alert.messageText = "恢复为这个备份的状态？"
      alert.informativeText =
        "包含 \(preview.entries.count) 条原文、\(preview.people.count) 位人物、\(preview.memories.count) 条记忆。当前状态会先备份，恢复旧备份可能恢复之前删除的内容。"
      alert.addButton(withTitle: "确认恢复")
      alert.addButton(withTitle: "取消")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
      for worker in workers.values { worker.cancel() }
      queue = []
      invalidateQuery()
      cancelTools()
      Task {
        do {
          try await store.restore(data, expectedRevision: revision)
          await refresh()
          notice = "已恢复，旧请求不会自动重发"
        } catch { self.error = error.localizedDescription }
      }
    } catch { self.error = "备份未通过校验，当前数据保持不变：\(error.localizedDescription)" }
  }
}
extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
