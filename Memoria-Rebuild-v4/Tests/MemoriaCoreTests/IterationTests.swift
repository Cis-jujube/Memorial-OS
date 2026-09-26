import Foundation
import Testing

@testable import MemoriaCore

struct PersistenceIterationTests {
  @Test func deletingConfirmedSourceSurvivesReopen() async throws {
    let store = try temporaryStore()
    let memory = try await setupMemory(store)
    try await store.deleteEntry(memory.sourceID)
    let restored = try LocalStore(url: await store.url)
    let state = await restored.snapshot()
    #expect(state.activeMemories.isEmpty)
    #expect(state.entries.first?.original(1) == memory.item.source_quote)
    #expect(try LocalStore.decodeBackup(await store.export()).entries.first?.deleted == true)
  }
  @Test func deletingEditedPendingSourceSurvivesReopen() async throws {
    let store = try temporaryStore()
    let source = try await store.capture(Entry(text: "tea"), operationID: uid())
    try await store.editEntry(source.id, revision: 1, text: "coffee")
    _ = try await store.manualProposal(
      sourceID: source.id, item: EntryItem(text: "coffee", source_quote: "coffee"), personID: nil)
    try await store.deleteEntry(source.id)
    try await store.deleteEntry(source.id)
    let state = await (try LocalStore(url: await store.url)).snapshot()
    #expect(state.entries.first?.history.count == 2)
    #expect(state.entries.first?.original(2) == "coffee")
  }
  @Test func manualMemoryPreservesPendingSiblings() async throws {
    let store = try temporaryStore()
    let source = try await store.capture(Entry(text: "Tea and books"), operationID: uid())
    let first = try await store.manualProposal(
      sourceID: source.id, item: EntryItem(text: "Tea", source_quote: "Tea"), personID: nil)
    let second = try await store.manualProposal(
      sourceID: source.id, item: EntryItem(text: "Books", source_quote: "books"), personID: nil)
    _ = try await store.confirm(second.id, revision: second.revision)
    let state = await store.snapshot()
    #expect(state.proposals.first { $0.id == first.id }?.status == .pending)
  }
  @Test func revokedMemoryCanBeOrganizedAgain() async throws {
    let store = try temporaryStore()
    let memory = try await setupMemory(store)
    try await store.revoke(memory.id, expected: memory.revision)
    let task = try await store.begin(memory.sourceID)
    try await store.install(EntryAnalysis(items: [memory.item]), task: task)
    let state = await store.snapshot()
    #expect(state.proposals.filter { $0.status == .pending }.count == 1)
    #expect(state.activeMemories.isEmpty)
  }
  @Test func resolvingPlanOnlyAfterValidSave() async throws {
    let store = try temporaryStore()
    let source = try await store.capture(Entry(text: "Meet next week"), operationID: uid())
    let p = try await store.manualProposal(
      sourceID: source.id,
      item: EntryItem(kind: .plan, text: "Meet next week", source_quote: source.text), personID: nil
    )
    var action = ActionDraft(payload: OutingPayload(title: "", start: nil, end: nil))
    do {
      _ = try await store.execute(action, resolving: p)
      Issue.record("Empty title accepted")
    } catch {}
    #expect(await store.snapshot().proposals.first?.status == .pending)
    action = ActionDraft(payload: OutingPayload(title: "Meet next week", start: nil, end: nil))
    let id = try await store.execute(action, resolving: p)
    #expect(try await store.execute(action, resolving: p) == id)
    let reopened = try LocalStore(url: await store.url)
    #expect(await reopened.snapshot().proposals.first?.status == .confirmed)
    #expect(await reopened.snapshot().outings.count == 1)
  }
  @Test func editRejectsBlankAndOversizedRecords() async throws {
    let store = try temporaryStore()
    let source = try await store.capture(Entry(text: "original"), operationID: uid())
    for invalid in [" \n", String(repeating: "a", count: 100_001)] {
      do {
        try await store.editEntry(source.id, revision: 1, text: invalid)
        Issue.record("Invalid edit accepted")
      } catch {}
    }
    #expect(await store.snapshot().entries.first?.text == "original")
  }
}
struct ChatImportTests {
  @Test func preservesUnicodeSendersTimesAndOrder() throws {
    let items = try ChatImport.parse("小林 2026-09-22 10:00\r\n喜欢茶🍵\r\n\r\n我 10:01\r\n下周见")
    #expect(items.map(\.text) == ["小林 2026-09-22 10:00\n喜欢茶🍵", "我 10:01\n下周见"])
    #expect(try ChatImport.parse("one\n\ntwo", splitParagraphs: false).count == 1)
    #expect(try ChatImport.parse("one\n\n \n two\n\none").map(\.text) == ["one", "two"])
  }
  @Test func invalidInputHasBoundedLimits() {
    for input in [
      "  ", String(repeating: "a", count: 100_001),
      (0..<501).map { "item \($0)" }.joined(separator: "\n\n"),
      String(repeating: "🍵", count: 500_001),
    ] {
      #expect(throws: (any Error).self) { try ChatImport.parse(input) }
    }
  }
  @Test func selectedImportIsAtomicLocalAndIdempotentAcrossReopen() async throws {
    let store = try temporaryStore()
    let excerpts = try ChatImport.parse("Alice 10:00\nTea\n\nBob 10:01\nCoffee")
    let receipt = try await store.importExcerpts([excerpts[1]], personID: nil)
    #expect(receipt.added == 1)
    let reopened = try LocalStore(url: await store.url)
    let revisionBeforeDuplicate = await reopened.snapshot().revision
    let duplicate = try await reopened.importExcerpts([excerpts[1]], personID: nil)
    #expect(duplicate.added == 0 && duplicate.skipped == 1)
    #expect(await reopened.snapshot().revision == revisionBeforeDuplicate)
    let state = await reopened.snapshot()
    #expect(state.entries.map(\.text) == ["Bob 10:01\nCoffee"])
    #expect(state.proposals.isEmpty && state.memories.isEmpty && state.tasks.isEmpty)
    try await reopened.deleteEntry(state.entries[0].id)
    #expect(try await reopened.importExcerpts([excerpts[1]], personID: nil).skipped == 1)
  }
  @Test func invalidPersonAndDiskFailureLeaveNoPartialImport() async throws {
    let store = try temporaryStore()
    let excerpts = try ChatImport.parse("one\n\ntwo")
    do {
      _ = try await store.importExcerpts(excerpts, personID: "missing")
      Issue.record("Missing person accepted")
    } catch {}
    #expect(await store.snapshot().entries.isEmpty)
    let broken = try LocalStore(
      url: await store.url.deletingLastPathComponent().appendingPathComponent("broken.json"),
      writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
    do {
      _ = try await broken.importExcerpts(excerpts, personID: nil)
      Issue.record("Write failure swallowed")
    } catch {}
    #expect(await broken.snapshot().entries.isEmpty)
  }
}
struct BilingualRecallTests {
  @Test func englishIntentRetrievesChineseMemoryWithoutCrossPersonLeak() async throws {
    let store = try temporaryStore()
    let alice = Person(name: "Alice")
    let bob = Person(name: "Bob")
    try await store.savePerson(alice)
    try await store.savePerson(bob)
    let memory = try await setupMemory(store, person: alice)
    _ = try await setupMemory(store, text: "Coffee", person: bob)
    let result = RecallService.query(
      "What does alice enjoy?", personID: nil, state: await store.snapshot(), language: "en")
    #expect(result.candidates.map(\.id) == [memory.id])
    #expect(result.answer.statements.first?.text == "喜欢安静的展览")
  }
  @Test func englishPronounClarificationPreservesBirthdayIntent() async throws {
    let store = try temporaryStore()
    var alice = Person(name: "Alice")
    alice.importantDate = "生日 5月6日"
    try await store.savePerson(alice)
    let state = await store.snapshot()
    let question = "When is her birthday?"
    let unresolved = RecallService.query(question, personID: nil, state: state, language: "en")
    #expect(unresolved.answer.status == "needs_clarification")
    #expect(unresolved.answer.clarification == "Which friend are you asking about?")
    let resolved = RecallService.query(question, personID: alice.id, state: state, language: "en")
    #expect(resolved.candidates.count == 1)
    #expect(resolved.candidates.first?.item.text.contains("生日") == true)
  }
  @Test func englishNoResultsAndWeatherAreExplanatory() {
    let result = RecallService.query(
      "What is the weather?", personID: nil, state: LibraryState(), language: "en")
    #expect(result.answer.next_step == "lookup_current_information")
    #expect(result.answer.missing_info.allSatisfy { !$0.contains("需要") && !$0.contains("没有") })
  }
  @Test func translationCatalogContainsEveryPrimaryPageAndStatus() {
    for key in [
      "记录", "问一问", "人物", "行程", "设置", "整理台", "导入", "原文已保存", "建议待确认", "确认", "取消", "保存", "查看来源",
    ] {
      #expect(InterfaceCopy.text(key, language: "en") != key)
      #expect(InterfaceCopy.text(key, language: "zh") == key)
    }
    #expect(
      InterfaceCopy.text("Alice's original words", language: "en") == "Alice's original words")
  }
}

struct SecondIterationRegressionTests {
  @Test func resolvedPlanIsNotReproposed() async throws {
    let store = try temporaryStore()
    let e = try await store.capture(Entry(text: "Meet next week"), operationID: uid())
    let item = EntryItem(kind: .plan, text: "Meet next week", source_quote: e.text)
    let task = try await store.begin(e.id)
    try await store.install(EntryAnalysis(items: [item]), task: task)
    let p = await store.snapshot().proposals[0]
    _ = try await store.execute(
      ActionDraft(payload: OutingPayload(title: item.text, start: nil, end: nil)), resolving: p)
    let again = try await store.begin(e.id)
    try await store.install(EntryAnalysis(items: [item]), task: again)
    #expect(await store.snapshot().proposals.filter { $0.status == .pending }.isEmpty)
    #expect(await store.snapshot().outings.count == 1)
    #expect(await store.snapshot().tasks.last?.phase == .no_suggestions)
  }
  @Test func editedOrganizedSourceReturnsToUnorganized() async throws {
    let store = try temporaryStore()
    let e = try await store.capture(Entry(text: "Tea"), operationID: uid())
    let task = try await store.begin(e.id)
    try await store.install(
      EntryAnalysis(items: [EntryItem(text: "Tea", source_quote: "Tea")]), task: task)
    try await store.editEntry(e.id, revision: 1, text: "Coffee")
    let state = await store.snapshot()
    let edited = state.entries[0]
    #expect(ReviewQueue.isUnorganized(edited, in: state))
    #expect(!ReviewQueue.needsAttention(edited, in: state))
    #expect(ReviewQueue.currentTask(for: edited, in: state) == nil)
    #expect(state.proposals.allSatisfy { $0.status == .stale })
  }
  @Test func queuedAndFailedRecordsNeedAttentionWithoutSuggestions() async throws {
    let store = try temporaryStore()
    let e = try await store.capture(Entry(text: "A record"), operationID: uid())
    let task = try await store.begin(e.id)
    #expect(ReviewQueue.needsAttention(e, in: await store.snapshot()))
    try await store.transition(task, phase: .failed, error: "No model configured")
    let state = await store.snapshot()
    #expect(state.proposals.isEmpty)
    #expect(ReviewQueue.needsAttention(e, in: state))
  }
  @Test func emptySuccessfulExtractionStillRequiresWholeOriginalReview() async throws {
    let store = try temporaryStore()
    let entry = try await store.capture(Entry(text: "An ambiguous note"), operationID: uid())
    let task = try await store.begin(entry.id)
    try await store.install(EntryAnalysis(items: []), task: task)
    #expect(ReviewQueue.needsAttention(entry, in: await store.snapshot()))
    try await store.markReviewed(entry.id, revision: entry.revision, requestID: task.request_id)
    #expect(!ReviewQueue.needsAttention(entry, in: await store.snapshot()))
  }
  @Test func confirmingLastSuggestionDoesNotCompleteWholeOriginalReview() async throws {
    let store = try temporaryStore()
    let entry = try await store.capture(Entry(text: "Alice likes tea"), operationID: uid())
    let task = try await store.begin(entry.id)
    try await store.install(
      EntryAnalysis(items: [EntryItem(text: entry.text, source_quote: entry.text)]), task: task)
    let proposal = await store.snapshot().proposals[0]
    _ = try await store.confirm(proposal.id, revision: proposal.revision)
    #expect(ReviewQueue.needsAttention(entry, in: await store.snapshot()))
    try await store.markReviewed(entry.id, revision: entry.revision, requestID: task.request_id)
    #expect(!ReviewQueue.needsAttention(entry, in: await store.snapshot()))
  }
  @Test func retryDoesNotDuplicatePendingSuggestion() async throws {
    let store = try temporaryStore()
    let entry = try await store.capture(Entry(text: "Alice likes tea"), operationID: uid())
    let item = EntryItem(text: "Alice likes tea", source_quote: entry.text)
    for _ in 0..<2 {
      let task = try await store.begin(entry.id)
      try await store.install(EntryAnalysis(items: [item]), task: task)
    }
    let state = await store.snapshot()
    #expect(state.proposals.filter { $0.status == .pending }.count == 1)
    #expect(state.tasks.last?.phase == .awaiting_review)
    #expect(state.proposals.filter { $0.status == .stale }.count == 1)
  }
  @Test func ordinaryEnglishWordsDoNotSelectOtherPeople() async throws {
    let store = try temporaryStore()
    for name in ["Ann", "Will"] {
      let p = Person(name: name)
      try await store.savePerson(p)
      _ = try await setupMemory(store, text: name + " likes coffee", person: p)
    }
    let own = try await setupMemory(store, text: "I enjoy tea")
    for q in ["What do I enjoy planning?", "What will I enjoy?", "Will I enjoy an outing?"] {
      let result = RecallService.query(
        q, personID: nil, state: await store.snapshot(), language: "en")
      #expect(result.answer.status == "needs_clarification")
      #expect(result.candidates.isEmpty)
      let selected = RecallService.query(
        q, personID: "__self", state: await store.snapshot(), language: "en")
      #expect(selected.candidates.map(\.id) == [own.id])
    }
    let named = RecallService.query(
      "What does Ann enjoy?", personID: nil, state: await store.snapshot(), language: "en")
    #expect(named.candidates.first?.item.text == "Ann likes coffee")
    let will = RecallService.query(
      "What does Will enjoy?", personID: nil, state: await store.snapshot(), language: "en")
    #expect(will.candidates.first?.item.text == "Will likes coffee")
  }
  @Test func nameHomographsDoNotOverridePronounClarification() async throws {
    let store = try temporaryStore()
    let will = Person(name: "Will")
    let alice = Person(name: "Alice")
    try await store.savePerson(will)
    try await store.savePerson(alice)
    let memory = try await setupMemory(store, text: "Will enjoys tea", person: will)
    let aliceMemory = try await setupMemory(store, text: "Alice enjoys art", person: alice)
    _ = try await setupMemory(store, text: "I enjoy coffee")
    let state = await store.snapshot()
    let explicit = RecallService.query(
      "Tell me what Will enjoys", personID: nil, state: state, language: "en")
    #expect(explicit.candidates.map(\.id) == [memory.id])
    let ambiguous = RecallService.query(
      "Will she enjoy an outing?", personID: nil, state: state, language: "en")
    #expect(ambiguous.answer.status == "needs_clarification")
    #expect(ambiguous.candidates.isEmpty)
    let auxiliaryWithName = RecallService.query(
      "What will Alice enjoy?", personID: alice.id, state: state, language: "en")
    #expect(auxiliaryWithName.candidates.map(\.id) == [aliceMemory.id])
  }
  @Test func everydayBilingualFactsAndGoalsAreRetrieved() async throws {
    let store = try temporaryStore()
    let person = Person(name: "小林")
    try await store.savePerson(person)
    for (kind, value) in [
      (Kind.fact, "住在昆山"), (.fact, "在杜克大学学习"), (.fact, "工作是设计师"), (.goal, "目标是学会游泳"),
    ] {
      let e = try await store.capture(Entry(text: value, personID: person.id), operationID: uid())
      let p = try await store.manualProposal(
        sourceID: e.id,
        item: EntryItem(kind: kind, subject: person.name, text: value, source_quote: value),
        personID: person.id)
      _ = try await store.confirm(p.id, revision: p.revision)
    }
    for (q, expected) in [
      ("小林住在哪里？", "住在昆山"), ("Where does she live?", "住在昆山"), ("她在哪里上学？", "在杜克大学学习"),
      ("Where does she study?", "在杜克大学学习"), ("她做什么工作？", "工作是设计师"),
      ("What are her goals?", "目标是学会游泳"),
    ] {
      let result = RecallService.query(
        q, personID: person.id, state: await store.snapshot(), language: "en")
      #expect(result.candidates.map(\.item.text) == [expected])
    }
  }
}

struct AtomicOutingPlanTests {
  @Test func newOutingStatusReflectsReminderBeforeNotificationSync() throws {
    let noReminder = Outing(payload: OutingPayload(title: "Untimed draft"))
    let reminder = Outing(
      payload: OutingPayload(title: "Meet Alice", reminder: Date().addingTimeInterval(3600)))
    #expect(noReminder.notificationStatus == "未设置提醒")
    #expect(reminder.notificationStatus == "通知需要更新")
    let decoded = try JSONDecoder().decode(Outing.self, from: JSONEncoder().encode(reminder))
    #expect(decoded.notificationStatus == "通知需要更新")
  }
  @Test func unresolvedPlanCanSaveDraftWithoutConfirmingSourceProposal() async throws {
    let store = try temporaryStore()
    let entry = try await store.capture(
      Entry(text: "Charlie wants a museum visit"), operationID: uid())
    let task = try await store.begin(entry.id)
    try await store.install(
      EntryAnalysis(items: [
        EntryItem(kind: .plan, subject: "Charlie", text: entry.text, source_quote: entry.text)
      ]), task: task)
    let proposal = await store.snapshot().proposals[0]
    #expect(proposal.issue != nil)
    let action = ActionDraft(payload: OutingPayload(title: "Museum draft", start: nil, end: nil))
    do {
      _ = try await store.execute(action, resolving: proposal)
      Issue.record("Unresolved plan was confirmed")
    } catch {}
    #expect(await store.snapshot().outings.isEmpty)
    _ = try await store.execute(action)
    #expect(await store.snapshot().outings.count == 1)
    #expect(await store.snapshot().proposals[0].status == .pending)
  }
  @Test func invalidActionDoesNotPersistUnattachedPlan() async throws {
    let store = try temporaryStore()
    let place = Place(
      name: "Synthetic park", address: "Synthetic address", latitude: 31, longitude: 121,
      url: "https://maps.apple.com/?ll=31,121")
    let plan = OutingPlan(stops: [Stop(place: place)], memoryIDs: [], budget: nil, notes: "Test")
    var action = ActionDraft(payload: OutingPayload(title: "", location: place.name))
    action.proposal_id = plan.id
    action.proposal_revision = plan.revision
    do {
      _ = try await store.execute(action, plan: plan)
      Issue.record("Invalid outing accepted")
    } catch {}
    #expect(await store.snapshot().plans.isEmpty)
    action.payload?.title = "Synthetic outing"
    let id = try await store.execute(action, plan: plan)
    let reopened = try LocalStore(url: await store.url)
    #expect(await reopened.snapshot().plans.count == 1)
    #expect(await reopened.snapshot().outings.first?.id == id)
  }
}

struct StorageCapacityTests {
  @Test func archiveStartsEmptyLibraryWithoutLosingRestorableHistory() async throws {
    let store = try temporaryStore()
    let entry = try await store.capture(Entry(text: "Original source"), operationID: uid())
    try await store.editEntry(entry.id, revision: entry.revision, text: "Corrected source")
    let archive = try await store.archiveAndStartNew()
    #expect(await store.snapshot().entries.isEmpty)
    #expect(
      try LocalStore.decodeBackup(Data(contentsOf: archive)).entries.first?.original(1)
        == "Original source")
    let newEntry = try await store.capture(Entry(text: "New library"), operationID: uid())
    #expect(await store.snapshot().entries.map(\.id) == [newEntry.id])
    let archivedData = try Data(contentsOf: archive)
    let currentRevision = await store.snapshot().revision
    try await store.restore(archivedData, expectedRevision: currentRevision)
    #expect(await store.snapshot().entries.first?.text == "Corrected source")
  }
  @Test func unreadableLibraryCanRestoreValidatedBackupAndKeepOriginalBytes() async throws {
    let original = try temporaryStore()
    _ = try await original.capture(Entry(text: "Keep this source"), operationID: uid())
    let validBackup = try await original.export()
    let url = await original.url
    let unreadable = Data("{incomplete".utf8)
    try unreadable.write(to: url, options: .atomic)
    #expect(throws: (any Error).self) { try LocalStore(url: url) }
    #expect(throws: (any Error).self) { try LocalStore.recover(unreadable, at: url) }
    #expect(try Data(contentsOf: url) == unreadable)
    let recovered = try LocalStore.recover(validBackup, at: url)
    #expect(await recovered.snapshot().entries.first?.text == "Keep this source")
    let archives = try FileManager.default.contentsOfDirectory(
      at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("before-restore-unreadable-") }
    #expect(archives.count == 1)
    #expect(try Data(contentsOf: archives[0]) == unreadable)
  }
  @Test func oversizedTransactionCannotMakeLibraryUnreadable() async throws {
    let store = try temporaryStore()
    let original = try await store.capture(Entry(text: "Keep this record"), operationID: uid())
    var huge = Person(name: "Synthetic capacity test")
    huge.aliases = [String(repeating: "a", count: 20_000_000)]
    do {
      try await store.savePerson(huge)
      Issue.record("Oversized library was saved")
    } catch {}
    let reopened = try LocalStore(url: await store.url)
    let state = await reopened.snapshot()
    #expect(state.people.isEmpty)
    #expect(state.entries.map(\.id) == [original.id])
  }
}

struct FinalScopeRegressionTests {
  @Test func unexpectedHttpFailureIsReadableInEnglish() {
    #expect(
      InterfaceCopy.text(MemoriaError.http(500).localizedDescription, language: "en")
        == "Service request failed (HTTP 500).")
  }
  @Test func selectedPersonCannotAnswerQuestionNamingSomebodyElse() async throws {
    let store = try temporaryStore()
    let alice = Person(name: "Alice")
    let bob = Person(name: "Bob")
    try await store.savePerson(alice)
    try await store.savePerson(bob)
    _ = try await setupMemory(store, text: "Alice likes tea", person: alice)
    _ = try await setupMemory(store, text: "Alice birthday is May 1", person: alice)
    let state = await store.snapshot()
    for scope in [alice.id, "__self"] {
      for question in [
        "What does Bob like?", "What does Charlie like?", "What are Charlie's interests?",
        "what are charlie's interests?", "Charlie's hobby?", "Tell me Charlie's birthday",
        "Charlie birthday?", "Charlie hobbies?", "Bob work?",
        "王小明的爱好是什么？", "张三喜欢什么？", "小明爱好是什么？",
        "小明的目标是什么？", "why bob likes tea", "bob likes tea?",
      ] {
        let result = RecallService.query(question, personID: scope, state: state, language: "en")
        #expect(result.answer.status == "needs_clarification")
        #expect(result.candidates.isEmpty)
      }
    }
    let selected = RecallService.query(
      "What does she like?", personID: alice.id, state: state, language: "en")
    #expect(selected.candidates.contains { $0.item.text == "Alice likes tea" })
    let birthday = RecallService.query(
      "Alice birthday?", personID: alice.id, state: state, language: "en")
    #expect(birthday.candidates.first?.item.text == "Alice birthday is May 1")
    let weekday = RecallService.query(
      "What does Alice like on Monday?", personID: alice.id, state: state, language: "en")
    #expect(weekday.candidates.contains { $0.item.text == "Alice likes tea" })
    for (question, scope) in [
      ("What are my interests?", alice.id), ("What does she like?", "__self"),
    ] {
      let result = RecallService.query(question, personID: scope, state: state, language: "en")
      #expect(result.answer.status == "needs_clarification")
      #expect(result.candidates.isEmpty)
    }
    let chinese = Person(name: "小明")
    try await store.savePerson(chinese)
    _ = try await setupMemory(store, text: "小明喜欢茶", person: chinese)
    let chineseState = await store.snapshot()
    for question in ["小明的爱好是什么？", "小明爱好是什么？", "他的爱好是什么？"] {
      let result = RecallService.query(question, personID: chinese.id, state: chineseState)
      #expect(result.answer.status == "found")
      #expect(result.candidates.first?.personID == chinese.id)
    }
  }
  @Test func unresolvedSubjectCannotBeConfirmedByClearingIssueAlone() async throws {
    let store = try temporaryStore()
    let entry = try await store.capture(Entry(text: "Charlie likes tea"), operationID: uid())
    let task = try await store.begin(entry.id)
    try await store.install(
      EntryAnalysis(items: [
        EntryItem(subject: "Charlie", text: entry.text, source_quote: entry.text)
      ]),
      task: task)
    var proposal = await store.snapshot().proposals[0]
    #expect(proposal.issue != nil)
    try await store.editProposal(proposal, expected: proposal.revision)
    proposal = await store.snapshot().proposals[0]
    #expect(proposal.issue == nil)
    do {
      _ = try await store.confirm(proposal.id, revision: proposal.revision)
      Issue.record("Unresolved person was confirmed")
    } catch {}
    #expect(await store.snapshot().activeMemories.isEmpty)
  }
  @Test func unknownPersonNeverFallsBackToSelf() async throws {
    let store = try temporaryStore()
    _ = try await setupMemory(store, text: "I enjoy tea")
    let entry = try await store.capture(Entry(text: "我的生日是5月6日"), operationID: uid())
    let proposal = try await store.manualProposal(
      sourceID: entry.id, item: EntryItem(kind: .fact, text: entry.text, source_quote: entry.text),
      personID: nil)
    _ = try await store.confirm(proposal.id, revision: proposal.revision)
    let goalEntry = try await store.capture(Entry(text: "我的目标是学会摄影"), operationID: uid())
    let goalProposal = try await store.manualProposal(
      sourceID: goalEntry.id,
      item: EntryItem(kind: .goal, text: goalEntry.text, source_quote: goalEntry.text),
      personID: nil)
    _ = try await store.confirm(goalProposal.id, revision: goalProposal.revision)
    let state = await store.snapshot()
    let unknownGoalInSelfScope = RecallService.query(
      "小明的目标是什么？", personID: "__self", state: state, language: "zh")
    #expect(unknownGoalInSelfScope.answer.status == "needs_clarification")
    #expect(unknownGoalInSelfScope.candidates.isEmpty)
    for question in [
      "What does Bob enjoy?", "小明喜欢什么？", "I wonder what Bob likes",
      "Can I ask about Bob's birthday?", "我想知道张三的生日", "我想知道小明喜欢什么",
      "小明的目标是什么？",
    ] {
      let result = RecallService.query(question, personID: nil, state: state, language: "en")
      #expect(result.answer.status == "needs_clarification")
      #expect(result.candidates.isEmpty)
    }
    #expect(
      RecallService.query(
        "What are the interests?", personID: "__self", state: state, language: "en"
      ).candidates.count == 1)
    #expect(
      RecallService.query("Interests?", personID: "deleted-person", state: state, language: "en")
        .candidates.isEmpty)
  }
  @Test func partialManualConfirmationDoesNotCompleteWholeImportedSource() async throws {
    let store = try temporaryStore()
    let entry = try await store.capture(Entry(text: "Tea and music"), operationID: uid())
    let p = try await store.manualProposal(
      sourceID: entry.id, item: EntryItem(text: "Tea", source_quote: "Tea"), personID: nil)
    _ = try await store.confirm(p.id, revision: p.revision)
    #expect(ReviewQueue.isUnorganized(entry, in: await store.snapshot()))
    try await store.markReviewed(entry.id, revision: entry.revision, requestID: nil)
    let reopened = try LocalStore(url: await store.url)
    #expect(!ReviewQueue.isUnorganized(entry, in: await reopened.snapshot()))
    try await store.editEntry(entry.id, revision: entry.revision, text: "Tea and music and books")
    let state = await store.snapshot()
    #expect(ReviewQueue.isUnorganized(state.entries[0], in: state))
  }
  @Test func explicitManualReviewClosesAttentionWithoutDiscardingEvidence() async throws {
    let store = try temporaryStore()
    let e = try await store.capture(Entry(text: "Tea and music"), operationID: uid())
    let task = try await store.begin(e.id)
    try await store.transition(task, phase: .failed, error: "No model configured")
    let p = try await store.manualProposal(
      sourceID: e.id, item: EntryItem(text: "Tea", source_quote: "Tea"), personID: nil)
    #expect(ReviewQueue.needsAttention(e, in: await store.snapshot()))
    try await store.markReviewed(e.id, revision: 1, requestID: task.request_id)
    let state = await store.snapshot()
    #expect(!ReviewQueue.needsAttention(e, in: state))
    #expect(state.proposals.first { $0.id == p.id }?.status == .pending)
    #expect(state.tasks.last?.error == "No model configured")
    let reopened = try LocalStore(url: await store.url)
    #expect(!ReviewQueue.needsAttention(e, in: await reopened.snapshot()))
  }
}
