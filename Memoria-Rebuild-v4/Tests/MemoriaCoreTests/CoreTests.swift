import Foundation
import Testing

@testable import MemoriaCore

func temporaryStore() throws -> LocalStore {
  try LocalStore(
    url: FileManager.default.temporaryDirectory.appendingPathComponent(uid())
      .appendingPathComponent("store.json"))
}
func fixture(_ quote: String = "小林不喜欢咖啡") -> String {
  """
  {"schema_version":"2.0","items":[{"kind":"preference","subject":"小林","text":"不喜欢咖啡","source_quote":"\(quote)","evidence_mode":"direct","time_text":null,"scope_text":null,"clarification":null}],"unprocessed_quotes":[]}
  """
}
func setupMemory(_ store: LocalStore, text: String = "喜欢安静的展览", person: Person? = nil) async throws
  -> Memory
{
  let entry = try await store.capture(Entry(text: text, personID: person?.id), operationID: uid())
  let p = try await store.manualProposal(
    sourceID: entry.id,
    item: EntryItem(subject: person?.name ?? "我", text: text, source_quote: text),
    personID: person?.id)
  let id = try await store.confirm(p.id, revision: p.revision)
  return await store.snapshot().memories.first { $0.id == id }!
}
final class SchemaValidationTests {
  @Test func testValidUnicodeAndNegation() throws {
    let a = try Contract.analysis(fixture("小林不喜欢咖啡☕️"), source: "小林不喜欢咖啡☕️。")
    expectEqual(a.items[0].evidence_mode, .direct)
    expectEqual(a.items[0].text, "不喜欢咖啡")
  }
  @Test func testUnknownMissingEnumsAndNullReject() throws {
    for invalid in [
      fixture().replacingOccurrences(
        of: "\"schema_version\":\"2.0\"", with: "\"schema_version\":\"2.0\",\"progress\":100"),
      fixture().replacingOccurrences(of: "\"preference\"", with: "\"profile\""),
      fixture().replacingOccurrences(of: "\"不喜欢咖啡\"", with: "null"),
      fixture().replacingOccurrences(of: "\"scope_text\":null,", with: ""),
    ] {
      expectThrows(try Contract.analysis(invalid, source: "小林不喜欢咖啡"))
    }
  }
  @Test func testEvidenceAndRepeatedQuotesReject() {
    expectThrows(try Contract.analysis(fixture(), source: "小林喜欢茶"))
    expectThrows(try Contract.analysis(fixture(), source: "小林不喜欢咖啡。小林不喜欢咖啡"))
  }
  @Test func testTooManyItemsReject() throws {
    var json = try JSONSerialization.jsonObject(with: Data(fixture().utf8)) as! [String: Any]
    json["items"] = Array(repeating: (json["items"] as! [Any])[0], count: 9)
    expectThrows(try Contract.validate(json, schema: Contract.schema("entry-analysis.v2")))
  }
  @Test func testMalformedPayloadRejects() {
    expectThrows(try Contract.analysis("{\"items\":[", source: "a"))
  }
}
final class ReviewTransactionTests {
  @Test func testOnlyConfirmationEntersMemoryAndIdempotency() async throws {
    let store = try temporaryStore()
    let entry = try await store.capture(Entry(text: "喜欢茶"), operationID: "one")
    let duplicate = try await store.capture(Entry(text: "另一条"), operationID: "one")
    expectEqual(entry.id, duplicate.id)
    let p = try await store.manualProposal(
      sourceID: entry.id, item: EntryItem(text: "喜欢茶", source_quote: "喜欢茶"), personID: nil)
    var state = await store.snapshot()
    expectTrue(state.activeMemories.isEmpty)
    let id = try await store.confirm(p.id, revision: p.revision)
    let same = try await store.confirm(p.id, revision: p.revision)
    state = await store.snapshot()
    expectEqual(id, same)
    expectEqual(state.activeMemories.count, 1)
  }
  @Test func testSameTextDifferentOperationIsNewExperience() async throws {
    let store = try temporaryStore()
    _ = try await store.capture(Entry(text: "见面"), operationID: uid())
    _ = try await store.capture(Entry(text: "见面"), operationID: uid())
    let s = await store.snapshot()
    expectEqual(s.entries.count, 2)
  }
  @Test func testReplacementUndoAndSourceHistory() async throws {
    let store = try temporaryStore()
    let old = try await setupMemory(store, text: "以前喜欢咖啡")
    let e = try await store.capture(Entry(text: "现在不喜欢咖啡"), operationID: uid())
    let p = try await store.manualProposal(
      sourceID: e.id, item: EntryItem(text: e.text, source_quote: e.text), personID: nil,
      replacement: old)
    let new = try await store.confirm(p.id, revision: p.revision)
    var s = await store.snapshot()
    expectEqual(s.activeMemories.map(\.item.text), ["现在不喜欢咖啡"])
    try await store.revoke(new, expected: 1, undo: true)
    s = await store.snapshot()
    expectEqual(s.activeMemories.first?.id, old.id)
    try await store.editEntry(old.sourceID, revision: 1, text: "原文改写")
    s = await store.snapshot()
    expectEqual(s.entries.first { $0.id == old.sourceID }?.original(1), "以前喜欢咖啡")
  }
  @Test func testStaleReplacementFails() async throws {
    let store = try temporaryStore()
    let old = try await setupMemory(store)
    let e = try await store.capture(Entry(text: "现在喜欢音乐"), operationID: uid())
    let p = try await store.manualProposal(
      sourceID: e.id, item: EntryItem(text: e.text, source_quote: e.text), personID: nil,
      replacement: old)
    try await store.revoke(old.id, expected: old.revision)
    do {
      _ = try await store.confirm(p.id, revision: 1)
      failTest("stale accepted")
    } catch {}
  }
  @Test func testAtomicFailureDoesNotMutateMemoryOrDisk() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(uid())
      .appendingPathComponent("s.json")
    let store = try LocalStore(url: url, writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
    do {
      _ = try await store.capture(Entry(text: "必须保留"), operationID: uid())
      failTest()
    } catch {}
    let state = await store.snapshot()
    expectTrue(state.entries.isEmpty)
    expectFalse(FileManager.default.fileExists(atPath: url.path))
  }
  @Test func testBackupRestoreCorruptionAndReferenceChecks() async throws {
    let store = try temporaryStore()
    _ = try await setupMemory(store)
    let good = try await store.export()
    let state = await store.snapshot()
    do {
      try await store.restore(Data("broken".utf8), expectedRevision: state.revision)
      failTest()
    } catch {}
    let after = await store.snapshot()
    expectEqual(after.revision, state.revision)
    var bad = try LocalStore.decodeBackup(good)
    bad.memories[0].sourceID = "invented"
    expectThrows(try LocalStore.decodeBackup(JSONEncoder().encode(bad)))
    try await store.restore(good, expectedRevision: state.revision)
    let restored = await store.snapshot()
    expectEqual(restored.activeMemories.count, 1)
  }
  @Test func testDeletionInvalidatesMemory() async throws {
    let store = try temporaryStore()
    let m = try await setupMemory(store)
    try await store.deleteEntry(m.sourceID)
    let s = await store.snapshot()
    expectTrue(s.activeMemories.isEmpty)
  }
}
final class TaskLifecycleTests {
  @Test func testCancelledLateResponseRejected() async throws {
    let store = try temporaryStore()
    let e = try await store.capture(Entry(text: "小林不喜欢咖啡"), operationID: uid())
    let t = try await store.begin(e.id)
    try await store.transition(t, phase: .cancelled)
    do {
      try await store.install(Contract.analysis(fixture(), source: e.text), task: t)
      failTest()
    } catch {}
    let s = await store.snapshot()
    expectTrue(s.proposals.isEmpty)
    expectEqual(s.entries.count, 1)
  }
  @Test func testEditAndRetryInvalidateOldAttempt() async throws {
    let store = try temporaryStore()
    let e = try await store.capture(Entry(text: "小林不喜欢咖啡"), operationID: uid())
    let old = try await store.begin(e.id)
    try await store.editEntry(e.id, revision: 1, text: "小林喜欢茶")
    let current = try await store.begin(e.id)
    expectNotEqual(old.request_id, current.request_id)
    do {
      try await store.install(Contract.analysis(fixture(), source: e.text), task: old)
      failTest()
    } catch {}
  }
  @Test func testRestartMarksOnlyRunningInterrupted() async throws {
    let store = try temporaryStore()
    let e = try await store.capture(Entry(text: "hi"), operationID: uid())
    _ = try await store.begin(e.id)
    let restarted = try LocalStore(url: await store.url)
    let s = await restarted.snapshot()
    expectEqual(s.tasks.last?.phase, .interrupted)
  }
  @Test func testManualConfirmationInvalidatesLateModel() async throws {
    let store = try temporaryStore()
    let e = try await store.capture(Entry(text: "小林不喜欢咖啡"), operationID: uid())
    let t = try await store.begin(e.id)
    let p = try await store.manualProposal(
      sourceID: e.id, item: EntryItem(text: e.text, source_quote: e.text), personID: nil)
    _ = try await store.confirm(p.id, revision: p.revision)
    do {
      try await store.install(Contract.analysis(fixture(), source: e.text), task: t)
      failTest()
    } catch {}
    let s = await store.snapshot()
    expectEqual(s.memories.count, 1)
  }
}
final class MemoryRetrievalTests {
  @Test func testScopedRetrievalAndCorrection() async throws {
    let store = try temporaryStore()
    let person = Person(name: "小林")
    try await store.savePerson(person)
    let m = try await setupMemory(store, person: person)
    var s = await store.snapshot()
    let found = RecallService.query("小林有什么爱好", personID: nil, state: s)
    expectEqual(found.candidates.first?.id, m.id)
    let personality = RecallService.query("她性格怎么样", personID: person.id, state: s)
    expectTrue(personality.candidates.isEmpty)
    try await store.revoke(m.id, expected: 1)
    s = await store.snapshot()
    expectTrue(RecallService.query("小林有什么爱好", personID: nil, state: s).candidates.isEmpty)
  }
  @Test func testAmbiguousNameNeverMerges() async throws {
    let store = try temporaryStore()
    try await store.savePerson(Person(name: "小林", note: "同事"))
    try await store.savePerson(Person(name: "小林", note: "同学"))
    let result = RecallService.query("小林爱好", personID: nil, state: await store.snapshot())
    expectEqual(result.answer.status, "needs_clarification")
    expectTrue(result.candidates.isEmpty)
  }
  @Test func testUnrelatedCandidatesDoNotAnswerBirthday() async throws {
    let store = try temporaryStore()
    _ = try await setupMemory(store)
    let result = RecallService.query("我的生日", personID: "__self", state: await store.snapshot())
    expectEqual(result.answer.status, "not_found")
  }
}
final class RecallAnswerTests {
  @Test func testInventedSourcesRejected() throws {
    let json = """
      {"schema_version":"1.0","status":"found","statements":[{"text":"喜欢茶","statement_type":"recorded","source_ids":["fake"]}],"suggestions":[],"missing_info":[],"clarification":null,"next_step":"none"}
      """
    expectThrows(try Contract.recall(json, candidates: []))
  }
  @Test func testGeneralSuggestionCannotPretendPersonalEvidence() throws {
    let json = """
      {"schema_version":"1.0","status":"not_found","statements":[],"suggestions":[{"text":"聊聊近况","basis":"general","source_ids":[]}],"missing_info":[],"clarification":null,"next_step":"none"}
      """
    expectNoThrow(try Contract.recall(json, candidates: []))
    expectThrows(
      try Contract.recall(
        json.replacingOccurrences(of: "general", with: "personalized"), candidates: []))
  }
}
final class ProviderContractTests {
  func client(_ provider: Provider) -> ModelClient {
    var c = ProviderConfig()
    c.provider = provider
    c.model = "test-model"
    return ModelClient(config: c, key: "synthetic-key")
  }
  @Test func testSixProvidersEncodeCorrectProtocolFamily() throws {
    for provider in Provider.allCases {
      let client = client(provider)
      let request = try client.request(
        system: "system", messages: [client.user("hello")], tools: ToolService.definitions)
      let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
      expectEqual(request.httpMethod, "POST")
      expectNotNil(body["tools"])
      if provider == .claude {
        expectEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        expectNotNil(body["system"])
      } else if provider == .gemini {
        expectNotNil(body["contents"])
        expectNotNil(body["systemInstruction"])
        expectNil(request.url?.query)
      } else {
        expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
        expectNotNil(body["messages"])
      }
    }
  }
  @Test func testToolIDsOpaqueFieldsAndRoundTrip() throws {
    let open = client(.deepseek)
    let raw: [String: Any] = [
      "role": "assistant", "content": NSNull(), "reasoning_content": "opaque",
      "tool_calls": [
        [
          "id": "call-123", "type": "function",
          "function": ["name": "search_places", "arguments": "{}"],
        ]
      ],
    ]
    let reply = try open.parse(["choices": [["message": raw, "finish_reason": "tool_calls"]]])
    expectEqual(reply.calls[0].id, "call-123")
    expectEqual(reply.raw["reasoning_content"] as? String, "opaque")
    expectEqual(
      open.toolResults([(reply.calls[0], "ok")])[0]["tool_call_id"] as? String, "call-123")
    let gemini = client(.gemini)
    let gem = try gemini.parse([
      "candidates": [
        [
          "content": [
            "role": "model",
            "parts": [
              [
                "thoughtSignature": "opaque-sig",
                "functionCall": ["id": "g1", "name": "search_places", "args": [:]],
              ]
            ],
          ]
        ]
      ]
    ])
    let parts = gem.raw["parts"] as! [[String: Any]]
    expectEqual(parts[0]["thoughtSignature"] as? String, "opaque-sig")
    expectEqual(gem.calls[0].id, "g1")
    expectNotNil(gemini.toolResults([(gem.calls[0], "ok")])[0]["parts"])
    let claude = client(.claude)
    let cla = try claude.parse([
      "content": [["type": "tool_use", "id": "c1", "name": "search_places", "input": [:]]]
    ])
    let blocks = claude.toolResults([(cla.calls[0], "ok")])[0]["content"] as! [[String: Any]]
    expectEqual(blocks[0]["tool_use_id"] as? String, "c1")
  }
  @Test func testTruncationAndEmptyResponse() throws {
    expectThrows(
      try client(.openai).parse([
        "choices": [["message": ["content": "{}"], "finish_reason": "length"]]
      ]))
    expectThrows(try client(.gemini).parse([:]))
  }
  @Test func testHTTPFailuresAreNotSuccessfulOutputs() async throws {
    var config = ProviderConfig()
    config.model = "test"
    let client = ModelClient(
      config: config, key: "fake",
      transport: { req in
        (
          Data("{}".utf8),
          HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
        )
      })
    do {
      _ = try await client.complete(system: "x", messages: [client.user("x")])
      failTest()
    } catch { expectTrue(error.localizedDescription.contains("限流")) }
  }
}
final class DecisionProviderTests {
  @Test func testJevRequestAndAbstention() async throws {
    let adapter = JevAdapter(
      key: "synthetic",
      transport: { req in
        let json = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        expectNotNil(json["state"])
        expectNotNil(json["questions"])
        expectNil(json["messages"])
        return (
          Data(
            "{\"model\":\"jev-test\",\"answers\":{\"support_0\":{\"choice\":\"unclear\"},\"relation_0\":{\"choice\":\"no_match\"}}}"
              .utf8),
          HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
      })
    let result = try await adapter.evaluate(
      source: Entry(text: "我喜欢茶"), items: [EntryItem(text: "喜欢茶", source_quote: "我喜欢茶")],
      memories: [])
    expectFalse(result.supported)
  }
  @Test func testMissingKeyDoesNotNeedNetwork() async throws {
    do {
      _ = try await JevAdapter(key: "").evaluate(source: Entry(text: "a"), items: [], memories: [])
      failTest()
    } catch { expectTrue(error.localizedDescription.contains("密钥")) }
  }
}
final class OutingValidationTests {
  @Test func testIncompleteDraftUnknownCostAndInvalidDates() throws {
    let draft = ActionDraft(payload: OutingPayload(title: "看展"))
    expectNoThrow(try Contract.action(draft, state: LibraryState()))
    let invalid = ActionDraft(
      payload: OutingPayload(title: "看展", start: Date(), end: Date().addingTimeInterval(-60)))
    expectThrows(try Contract.action(invalid, state: LibraryState()))
    let negative = ActionDraft(payload: OutingPayload(title: "看展", cost: -1))
    expectThrows(try Contract.action(negative, state: LibraryState()))
  }
  @Test func testCreateIdempotentAndStaleCancelRejected() async throws {
    let store = try temporaryStore()
    let action = ActionDraft(payload: OutingPayload(title: "看展"))
    let id = try await store.execute(action)
    let again = try await store.execute(action)
    expectEqual(id, again)
    var cancel = ActionDraft(payload: nil)
    cancel.operation = "cancel"
    cancel.target_id = id
    cancel.expected_target_revision = 2
    do {
      _ = try await store.execute(cancel)
      failTest()
    } catch {}
    cancel.expected_target_revision = 1
    _ = try await store.execute(cancel)
    let state = await store.snapshot()
    expectTrue(state.outings[0].cancelled)
    expectEqual(state.outings.count, 1)
  }
  @Test func testUnknownToolReturnsError() async {
    let service = ToolService(publicQuery: "test", date: "2026-09-22", budget: nil, memories: [])
    let result = await service.execute(ToolCall(id: "bad", name: "send_message", arguments: [:]))
    expectEqual(result.status, "error")
  }
}

func expectEqual<T: Equatable>(
  _ lhs: T, _ rhs: T, sourceLocation: SourceLocation = #_sourceLocation
) { #expect(lhs == rhs, sourceLocation: sourceLocation) }
func expectNotEqual<T: Equatable>(
  _ lhs: T, _ rhs: T, sourceLocation: SourceLocation = #_sourceLocation
) { #expect(lhs != rhs, sourceLocation: sourceLocation) }
func expectTrue(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
  #expect(value, sourceLocation: sourceLocation)
}
func expectFalse(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
  #expect(!value, sourceLocation: sourceLocation)
}
func expectNil<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) {
  #expect(value == nil, sourceLocation: sourceLocation)
}
func expectNotNil<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) {
  #expect(value != nil, sourceLocation: sourceLocation)
}
func expectThrows<T>(
  _ value: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation
) {
  do {
    _ = try value()
    Issue.record("Expected an error", sourceLocation: sourceLocation)
  } catch {}
}
func expectNoThrow<T>(
  _ value: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation
) { do { _ = try value() } catch { Issue.record(error, sourceLocation: sourceLocation) } }
func failTest(
  _ message: String = "Unexpected success", sourceLocation: SourceLocation = #_sourceLocation
) { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }

final class ExtendedBoundaryTests {
  @Test func testChunkingPreservesEveryCharacterAndEmoji() {
    let text = String(repeating: "小林说她喜欢展览☕️。条件仍未确定。\n", count: 300)
    let chunks = SourceChunker.split(text)
    expectEqual(chunks.joined(), text)
    expectTrue(chunks.allSatisfy { $0.count <= 1600 })
    expectTrue(chunks.count > 1)
  }
  @Test func testConfirmedChunkIsNotProposedAgain() async throws {
    let store = try temporaryStore()
    let m = try await setupMemory(store, text: "喜欢茶")
    let source = await store.snapshot().entries.first { $0.id == m.sourceID }!
    let task = try await store.begin(source.id)
    try await store.install(
      EntryAnalysis(items: [EntryItem(text: source.text, source_quote: source.text)]), task: task)
    let s = await store.snapshot()
    expectTrue(s.proposals.filter { $0.status == .pending }.isEmpty)
  }
  @Test func testPartialChunkPreservesUnprocessedText() async throws {
    let store = try temporaryStore()
    let source = try await store.capture(Entry(text: "喜欢茶。第二段暂未完成。"), operationID: uid())
    let task = try await store.begin(source.id)
    let first = ChunkReport(
      index: 0, text: "喜欢茶。",
      analysis: EntryAnalysis(items: [EntryItem(text: "喜欢茶", source_quote: "喜欢茶")]))
    let second = ChunkReport(index: 1, text: "第二段暂未完成。", error: "网络失败")
    try await store.install(ExtractionBatch(chunks: [first, second]), task: task)
    let s = await store.snapshot()
    expectEqual(s.proposals.count, 1)
    expectEqual(s.tasks.last?.unprocessed, ["第二段暂未完成。"])
    expectEqual(s.entries[0].text, source.text)
  }
  @Test func testPersonEditsCreateTraceableMemoryAndSupersedePriorVersion() async throws {
    let store = try temporaryStore()
    var p = Person(name: "小林", note: "性格描述来自用户印象：温和")
    try await store.savePerson(p)
    p.note = "性格描述来自用户印象：说话直接"
    try await store.savePerson(p, expected: 1)
    let s = await store.snapshot()
    expectEqual(s.activeMemories.count, 1)
    expectTrue(s.activeMemories[0].item.text.contains("说话直接"))
    expectEqual(s.memories.count, 2)
    expectNoThrow(try LocalStore.decodeBackup(JSONEncoder().encode(s)))
  }
  @Test func testSelectedIdentityResolvesDuplicateName() async throws {
    let store = try temporaryStore()
    let a = Person(name: "小林")
    let b = Person(name: "小林")
    try await store.savePerson(a)
    try await store.savePerson(b)
    _ = try await setupMemory(store, person: a)
    let result = RecallService.query("小林有什么爱好", personID: a.id, state: await store.snapshot())
    expectEqual(result.answer.status, "found")
    expectEqual(result.people.map(\.id), [a.id])
  }
  @Test func testConflictingExistingFactRequiresManualReviewWithoutJev() async throws {
    let store = try temporaryStore()
    _ = try await setupMemory(store, text: "喜欢咖啡")
    let source = try await store.capture(Entry(text: "现在不喝咖啡"), operationID: uid())
    let task = try await store.begin(source.id)
    try await store.install(
      EntryAnalysis(items: [EntryItem(text: source.text, source_quote: source.text)]), task: task)
    let s = await store.snapshot()
    expectNotNil(s.proposals.last?.issue)
    do {
      _ = try await store.confirm(s.proposals.last!.id, revision: 1)
      failTest()
    } catch {}
  }
  @Test func testConfirmationDiskFailureRetainsPendingProposal() async throws {
    final class Switch { var fail = false }
    let toggle = Switch()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(uid())
      .appendingPathComponent("s.json")
    let store = try LocalStore(
      url: url,
      writer: { data, url in
        if toggle.fail { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
      })
    let source = try await store.capture(Entry(text: "喜欢茶"), operationID: uid())
    let proposal = try await store.manualProposal(
      sourceID: source.id, item: EntryItem(text: source.text, source_quote: source.text),
      personID: nil)
    let before = try Data(contentsOf: url)
    toggle.fail = true
    do {
      _ = try await store.confirm(proposal.id, revision: 1)
      failTest()
    } catch {}
    let state = await store.snapshot()
    expectTrue(state.activeMemories.isEmpty)
    expectEqual(state.proposals.last?.status, .pending)
    expectEqual(try Data(contentsOf: url), before)
  }
  @Test func testAgentLoopRequiresActualProposalAndHonorsRoundBudget() async throws {
    final class Counter { var n = 0 }
    let count = Counter()
    var c = ProviderConfig()
    c.toolsDeclared = true
    let client = ModelClient(
      config: c, key: "synthetic",
      transport: { req in
        count.n += 1
        let response: [String: Any] = [
          "choices": [
            [
              "message": [
                "role": "assistant",
                "tool_calls": [
                  [
                    "id": "call-\(count.n)", "type": "function",
                    "function": ["name": "search_memories", "arguments": "{}"],
                  ]
                ],
              ]
            ]
          ]
        ]
        return (
          try JSONSerialization.data(withJSONObject: response),
          HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
      })
    let service = ToolService(publicQuery: "test", date: "2026-09-22", budget: 100, memories: [])
    do {
      _ = try await AgentRunner.run(client: client, tools: service, prompt: "test")
      failTest()
    } catch { expectTrue(error.localizedDescription.contains("四轮")) }
    expectEqual(count.n, 4)
  }
}

final class PlanConsistencyTests {
  @Test func testPlanRejectsParticipantAndSummaryMismatch() async throws {
    let store = try temporaryStore()
    let person = Person(name: "测试人物")
    try await store.savePerson(person)
    let memory = try await setupMemory(store, person: person)
    let place = Place(
      name: "测试地点", address: "测试地址", latitude: 31, longitude: 121,
      url: "https://maps.apple.com/?ll=31,121")
    let plan = OutingPlan(
      stops: [Stop(place: place)], memoryIDs: [memory.id], budget: 200, notes: "合成测试")
    try await store.savePlan(plan)
    try await store.savePlan(plan)
    var action = ActionDraft(payload: OutingPayload(title: "测试行程", location: place.name))
    action.proposal_id = plan.id
    action.proposal_revision = plan.revision
    let state = await store.snapshot()
    expectEqual(state.plans.count, 1)
    expectThrows(try Contract.action(action, state: state))
    action.payload?.participant_ids = [person.id]
    expectNoThrow(try Contract.action(action, state: state))
    action.payload?.location_name = "另一个地方"
    expectThrows(try Contract.action(action, state: state))
  }
}
