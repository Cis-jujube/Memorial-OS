import MemoriaCore
import SwiftUI

struct CaptureView: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ViewState private var search = ""
  @ViewState private var pendingOnly = false
  var entries: [Entry] {
    model.state.entries.filter { e in
      !e.deleted && (search.isEmpty || e.text.localizedCaseInsensitiveContains(search))
        && (!pendingOnly
          || model.state.proposals.contains { $0.sourceID == e.id && $0.status == .pending })
    }
  }
  var body: some View {
    PageTitle(title: L("留住今天的一点一滴"), subtitle: L("先写下来，慢慢整理。无需分类，也不必把话说得很完整。"))
    Card {
      VStack(alignment: .leading, spacing: 15) {
        HStack {
          Text(model.captureOuting == nil ? L("此刻，想记住什么？") : L("这次活动，有什么想反馈？")).font(TypeScale.body)
          Spacer()
          if model.demo { Text(L("演示样例")).font(TypeScale.body).foregroundStyle(accent) }
        }
        ZStack(alignment: .topLeading) {
          TextEditor(text: $model.draft).scrollContentBackground(.hidden).font(TypeScale.body)
            .frame(minHeight: 240).padding(14).background(
              paper.opacity(0.65), in: RoundedRectangle(cornerRadius: 16)
            ).overlay(RoundedRectangle(cornerRadius: 16).stroke(accent.opacity(0.14)))
            .accessibilityLabel(L("记录内容"))
          if model.draft.isEmpty {
            Text(L("今天和谁见了面，记住了什么，或者有什么想安排的事。")).foregroundStyle(ink.opacity(0.65)).padding(
              .top, 23
            )
            .padding(.leading, 21).allowsHitTesting(false)
          }
        }
        Divider()
        HStack {
          PersonPicker(selection: $model.capturePerson)
          Spacer()
          Button(L("仅保存")) { model.capture(organize: false) }.disabled(
            model.saving || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Button(model.saving ? L("正在保存…") : L("保存并整理")) { model.capture(organize: true) }
            .buttonStyle(
              WarmButtonStyle(primary: true)
            ).disabled(
              model.saving || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Text(model.demo ? L("演示使用固定合成响应，不代表真实模型效果。") : L("原文先保存在本机。云端整理需在设置中配置并启用；手动整理随时可用。")).font(
          TypeScale.body
        ).foregroundStyle(ink.opacity(0.68))
      }
    }
    HStack {
      Text(L("最近记录")).font(TypeScale.body.weight(.semibold))
      Spacer()
      Toggle(L("只看待确认"), isOn: $pendingOnly).toggleStyle(TextToggleStyle())
      TextField(L("搜索原文"), text: $search).textFieldStyle(WarmFieldStyle()).frame(width: 200)
    }
    if entries.isEmpty {
      if search.isEmpty && !pendingOnly && model.state.entries.allSatisfy(\.deleted) {
        EmptyMessage(title: L("从一条小事开始"), detail: L("写下最近的一次见面，或者一个不想忘记的偏好。你的记忆会在这里慢慢生长。"))
      } else {
        EmptyMessage(
          title: L("没有匹配的记录", "No matching records"),
          detail: L("试试其他关键词，或关闭“只看待确认”。", "Try another search or turn off Pending only."))
      }
    }
    LazyVStack(alignment: .leading, spacing: 18) {
      ForEach(entries) { entry in
        EntryCard(entry: entry)
          .frame(maxWidth: 900, alignment: .leading).padding(.leading, 24)
          .transition(
            .asymmetric(
              insertion: .opacity.combined(with: .move(edge: .top)),
              removal: .opacity.combined(with: .scale(scale: 0.97))))
      }
    }.animation(
      reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.76),
      value: model.state.revision)
  }
}
struct EntryCard: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var entry: Entry
  @ViewState private var expanded = false
  @ViewState private var manual = false
  @ViewState private var editing = false
  @ViewState private var text = ""
  @ViewState private var deleting = false
  @ViewState private var editBusy = false
  @ViewState private var editError = ""
  var proposals: [Proposal] {
    model.state.proposals.filter { $0.sourceID == entry.id && $0.status == .pending }
  }
  var task: TaskState? { ReviewQueue.currentTask(for: entry, in: model.state) }
  var body: some View {
    Card {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Text(displayDate(entry.created)).font(TypeScale.body)
            .foregroundStyle(ink.opacity(0.68))
          if entry.demo { Text(L("演示")).font(TypeScale.body).foregroundStyle(accent) }
          Spacer()
          Menu {
            Button(L("编辑原文")) {
              text = entry.text
              editing = true
            }
            Button(L("删除原文及其记忆"), role: .destructive) { deleting = true }
          } label: {
            Text(L("更多"))
          }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 68)
        }
        Text(entry.text).font(TypeScale.body).lineSpacing(6).textSelection(.enabled).lineLimit(
          5)
        if !entry.text.isEmpty {
          Button(L("查看完整原文", "Read original")) { model.sourcePreview = entry }
        }
        if let task {
          HStack {
            if task.phase.running { ProgressView().controlSize(.small) }
            Text(
              task.decisionStatus == ReviewQueue.reviewedDecision
                ? L("这条记录已整理", "Record reviewed")
                : task.phase == .awaiting_review && proposals.isEmpty
                  ? L("请检查完整原文", "Review the original") : L(task.phase.label)
            ).font(TypeScale.body).foregroundStyle(
              task.phase == .failed ? accent : ink.opacity(0.68))
            if task.phase.running {
              TimelineView(.periodic(from: task.started_at, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(task.started_at)))
                Text(
                  seconds >= 25
                    ? L("\(seconds) 秒 · 可取消或手动整理", "\(seconds)s · cancel or organize manually")
                    : seconds >= 8
                      ? L("\(seconds) 秒 · 可以继续使用其他页面", "\(seconds)s · other pages remain available")
                      : L("\(seconds) 秒", "\(seconds)s")
                ).font(TypeScale.body).foregroundStyle(ink.opacity(0.68))
              }
              Spacer()
              Button(L("取消整理")) { model.cancel(entry) }
            }
          }
          if let error = task.error { Text(L(error)).font(TypeScale.body).foregroundStyle(accent) }
          if !task.unprocessed.isEmpty {
            Text(L("还有未完整处理的内容：") + task.unprocessed.joined(separator: "；")).font(TypeScale.body)
              .foregroundStyle(accent)
          }
          if let decision = task.decisionStatus {
            DisclosureGroup(L("整理说明")) {
              Text(L(decision)).font(TypeScale.body).foregroundStyle(ink.opacity(0.68))
            }
          }
        }
        if task?.phase.running != true
          && (ReviewQueue.needsAttention(entry, in: model.state)
            || ReviewQueue.isUnorganized(entry, in: model.state))
        {
          Text(
            L(
              "检查完整原文后，可以标记已审阅。这会将记录从“需要处理”移出；错误、未确认建议和未处理片段仍可在最近记录中查看或重试。",
              "After checking the entire original, mark it reviewed. It leaves Needs attention; errors, pending suggestions and unprocessed excerpts remain in Recent records for review or retry."
            )
          ).foregroundStyle(ink.opacity(0.68))
          Button(L("已检查原文，标记已审阅", "I reviewed the original · Mark reviewed")) {
            model.perform {
              try await $0.markReviewed(
                entry.id, revision: entry.revision, requestID: task?.request_id)
            }
          }
        }
        ForEach(expanded ? proposals : Array(proposals.prefix(3))) { p in
          ProposalCard(proposal: p).transition(
            .opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
        }.animation(
          reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.68),
          value: proposals.map(\.id))
        if proposals.count > 3 && !expanded {
          Button(
            L("还有 \(proposals.count - 3) 条建议，展开查看", "Show \(proposals.count - 3) more suggestions")
          ) {
            withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.72)) {
              expanded = true
            }
          }
        }
        HStack {
          Button(L("手动整理")) { manual = true }
          if task?.phase.running != true {
            Button(task == nil ? L("整理这条记录") : L("重新整理")) { Task { await model.enqueue(entry) } }
          }
          Spacer()
        }.font(TypeScale.body)
        let approved = model.state.memories.filter {
          $0.sourceID == entry.id && $0.status == .active
        }
        if !approved.isEmpty {
          ForEach(approved) { m in
            HStack {
              Text(L("已记住：") + m.item.text).foregroundStyle(accent)
              Spacer()
              Button(L("撤销")) {
                model.perform { try await $0.revoke(m.id, expected: m.revision, undo: true) }
              }
            }.font(TypeScale.body)
          }
        }
      }
    }.sheet(isPresented: $manual) { ManualMemorySheet(entry: entry) }
      .sheet(isPresented: $editing) {
        VStack(alignment: .leading, spacing: 20) {
          Text(L("编辑原文")).font(TypeScale.title)
          Text(L("旧版本会保留为已确认记忆的历史依据。待确认建议将失效。")).foregroundStyle(ink.opacity(0.68))
          TextEditor(text: $text).font(TypeScale.body).frame(height: 240)
          if !editError.isEmpty { Text(editError).foregroundStyle(accent) }
          HStack {
            Button(L("取消")) { editing = false }
            Spacer()
            Button(editBusy ? L("正在保存…") : L("保存修改")) {
              guard let store = model.store else { return }
              editBusy = true
              Task {
                defer { editBusy = false }
                do {
                  try await store.editEntry(entry.id, revision: entry.revision, text: text)
                  await model.refresh()
                  editing = false
                } catch { editError = L(error.localizedDescription) }
              }
            }.disabled(
              editBusy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || text.count > 100_000
            ).buttonStyle(WarmButtonStyle(primary: true))
          }
        }.font(TypeScale.body).buttonStyle(WarmButtonStyle()).padding(32).frame(width: 560)
      }
      .confirmationDialog(L("删除这条原文及其关联记忆？后续检索将不再使用它。"), isPresented: $deleting) {
        Button(L("删除"), role: .destructive) {
          model.cancel(entry)
          model.perform { try await $0.deleteEntry(entry.id) }
        }
      }
  }
}
struct ProposalCard: View {
  @EnvironmentObject var model: AppModel
  var proposal: Proposal
  @ViewState private var editing = false
  @ViewState private var value = ""
  @ViewState private var person = ""
  @ViewState private var replacement = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        proposal.item.kind == .plan ? L("想安排：") + proposal.item.text : L("记住：") + proposal.item.text
      )
      .font(TypeScale.body.weight(.medium))
      Text(
        L("关联：")
          + (model.state.people.first { $0.id == proposal.personID }?.name
            ?? (proposal.item.subject == "我" ? L("自己", "Me") : proposal.item.subject)
              ?? L("尚未明确"))
      ).font(TypeScale.body).foregroundStyle(ink.opacity(0.68))
      if let issue = proposal.issue { Text(L(issue)).font(TypeScale.body).foregroundStyle(accent) }
      if let old = model.state.memories.first(where: { $0.id == proposal.replacementID }) {
        Text(L("替换：", "Replace: ") + old.item.text + " → " + proposal.item.text).font(
          TypeScale.body
        ).foregroundStyle(
          accent)
      }
      DisclosureGroup(L("查看依据")) {
        VStack(alignment: .leading) {
          Text("“\(proposal.item.source_quote)”").textSelection(.enabled)
          Text(
            proposal.edited
              ? L("表述由用户修改；引文是原始背景，不代表改写内容逐字出自原文。")
              : "\(proposal.item.evidence_mode.displayName) · \(proposal.item.time_text ?? L("时间未注明"))"
          ).font(TypeScale.body).foregroundStyle(ink.opacity(0.68))
        }
      }
      if let source = model.state.entries.first(where: {
        $0.id == proposal.sourceID && $0.revision == proposal.sourceRevision && !$0.deleted
      }) {
        Button(L("查看完整原文", "Read original")) { model.sourcePreview = source }
      }
      if editing {
        TextField(L("记忆内容"), text: $value).textFieldStyle(WarmFieldStyle())
        if proposal.issue == "请确认转述中的“我”指谁" {
          Text(
            L(
              "请重新选择引语中的“我”是谁；只有你自己说的原话才选择“自己”。",
              "Choose who said 'I' in the quote. Select Myself only if you said it."
            )
          ).font(TypeScale.body).foregroundStyle(accent)
        }
        if proposal.personID == nil && proposal.item.subject != "我" {
          Picker(L("关联人物", "Person"), selection: $person) {
            Text(L("请明确选择人物", "Choose a person")).tag("__choose")
            Text(L("自己", "Myself")).tag("")
            ForEach(model.state.people) { Text($0.name).tag($0.id) }
          }
        } else {
          PersonPicker(
            selection: $person, requireExplicit: proposal.issue == "请确认转述中的“我”指谁")
        }
        Picker(L("替换旧记忆（可选）"), selection: $replacement) {
          Text(L("新增记忆")).tag("")
          ForEach(model.state.activeMemories.filter { $0.personID == person.nilIfEmpty }) { m in
            Text(m.item.text).tag(m.id)
          }
        }
        Text(L("修改保存后仍需点击确认。请核对主体、否定、时间和条件。")).font(TypeScale.body).foregroundStyle(
          ink.opacity(0.68))
        HStack {
          Button(L("取消修改")) { editing = false }
          Button(L("保存修改")) {
            var p = proposal
            p.item.text = value
            p.personID = person.nilIfEmpty
            p.item.subject = model.state.people.first { $0.id == person }?.name ?? "我"
            p.replacementID = replacement.nilIfEmpty
            p.replacementRevision = model.state.memories.first { $0.id == replacement }?.revision
            let confirmedQuotedSelf = proposal.issue == "请确认转述中的“我”指谁" && person == ""
            model.perform {
              try await $0.editProposal(
                p, expected: proposal.revision,
                confirmedQuotedSelf: confirmedQuotedSelf)
            }
            editing = false
          }.disabled(value.isEmpty || person == "__choose")
        }
      } else {
        HStack {
          if proposal.item.kind == .plan {
            Button(L("去行程页补充时间")) {
              model.outingProposal = proposal
            }
          } else {
            Button(L("确认")) {
              model.perform { _ = try await $0.confirm(proposal.id, revision: proposal.revision) }
            }.buttonStyle(WarmButtonStyle(primary: true)).disabled(proposal.issue != nil)
          }
          Button(L("修改")) {
            value = proposal.item.text
            person =
              proposal.issue == "请确认转述中的“我”指谁"
              ? "__choose"
              : proposal.personID ?? (proposal.item.subject == "我" ? "" : "__choose")
            replacement = proposal.replacementID ?? ""
            editing = true
          }
          Button(L("忽略")) {
            model.perform { try await $0.ignore(proposal.id, revision: proposal.revision) }
          }
        }
      }
    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(
      accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
  }
}
struct ManualMemorySheet: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.dismiss) var dismiss
  var entry: Entry
  var replacementMemory: Memory? = nil
  @ViewState private var value = ""
  @ViewState private var person = ""
  @ViewState private var kind: Kind = .preference
  @ViewState private var replacement = ""
  @ViewState private var busy = false
  @ViewState private var formError = ""
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text(L("手动整理成记忆")).font(TypeScale.title)
        Text(entry.text).lineLimit(5).foregroundStyle(ink.opacity(0.68))
        TextField(L("要记住的内容"), text: $value, axis: .vertical).lineLimit(3...8).textFieldStyle(
          WarmFieldStyle())
        Text("\(value.count) / 500" + (value.count > 500 ? L(" · 内容过长", " · Too long") : ""))
          .foregroundStyle(value.count > 500 ? accent : ink.opacity(0.68))
        PersonPicker(selection: $person, requireExplicit: true)
        Text(
          L(
            "请自己写下要确认的记忆，并选择属于谁。",
            "Write the memory to confirm and choose whose it is."
          )
        ).foregroundStyle(ink.opacity(0.68))
        Picker(L("内容"), selection: $kind) {
          Text(L("偏好")).tag(Kind.preference)
          Text(L("事实 / 描述")).tag(Kind.fact)
          Text(L("共同经历")).tag(Kind.experience)
          Text(L("目标")).tag(Kind.goal)
          Text(L("备注")).tag(Kind.note)
        }
        Picker(L("更新已有记忆"), selection: $replacement) {
          Text(L("作为新记忆")).tag("")
          ForEach(model.state.activeMemories.filter { $0.personID == person.nilIfEmpty }) { m in
            Text(m.item.text).tag(m.id)
          }
        }
        Text(L("这是你直接填写的内容。保存即确认；原始记录与修改来源会一起保留。")).font(TypeScale.body).foregroundStyle(
          ink.opacity(0.68))
        if !formError.isEmpty { Text(formError).foregroundStyle(accent) }
        HStack {
          Button(L("取消")) { dismiss() }
          Spacer()
          Button(busy ? L("正在保存…") : L("确认保存")) {
            guard let store = model.store else { return }
            busy = true
            Task {
              do {
                let item = EntryItem(
                  kind: kind, subject: model.state.people.first { $0.id == person }?.name ?? "我",
                  text: value, source_quote: entry.text)
                let p = try await store.manualProposal(
                  sourceID: entry.id, item: item, personID: person.nilIfEmpty,
                  replacement: model.state.memories.first { $0.id == replacement })
                _ = try await store.confirm(p.id, revision: p.revision)
                await model.refresh()
                dismiss()
              } catch {
                formError = L(error.localizedDescription)
                busy = false
              }
            }
          }.buttonStyle(WarmButtonStyle(primary: true)).disabled(
            busy || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || value.count > 500 || person == "__choose"
          )
        }
      }.font(TypeScale.body).buttonStyle(WarmButtonStyle()).disclosureGroupStyle(
        TextDisclosureStyle()
      ).padding(32)
    }.frame(width: 600).frame(maxHeight: 650).onAppear {
      value = replacementMemory?.item.text ?? ""
      person = replacementMemory?.personID ?? entry.personID ?? "__choose"
      replacement = replacementMemory?.id ?? ""
    }
  }
}
