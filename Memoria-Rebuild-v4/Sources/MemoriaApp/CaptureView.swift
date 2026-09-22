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
    PageTitle(title: "留住今天的一点一滴", subtitle: "先写下来，慢慢整理。无需分类，也不必把话说得很完整。")
    Card {
      VStack(alignment: .leading, spacing: 15) {
        HStack {
          Text(model.captureOuting == nil ? "此刻，想记住什么？" : "这次活动，有什么想反馈？").font(TypeScale.body)
          Spacer()
          if model.demo { Text("演示样例").font(TypeScale.body).foregroundStyle(accent) }
        }
        ZStack(alignment: .topLeading) {
          TextEditor(text: $model.draft).scrollContentBackground(.hidden).font(TypeScale.body)
            .frame(minHeight: 240).padding(14).background(
              paper.opacity(0.65), in: RoundedRectangle(cornerRadius: 16)
            ).overlay(RoundedRectangle(cornerRadius: 16).stroke(accent.opacity(0.14)))
            .accessibilityLabel("记录内容")
          if model.draft.isEmpty {
            Text("今天和谁见了面，记住了什么，或者有什么想安排的事。").foregroundStyle(ink.opacity(0.65)).padding(.top, 23)
              .padding(.leading, 21).allowsHitTesting(false)
          }
        }
        Divider()
        HStack {
          PersonPicker(selection: $model.capturePerson)
          Spacer()
          Button("仅保存") { model.capture(organize: false) }.disabled(
            model.saving || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Button(model.saving ? "正在保存…" : "保存并整理") { model.capture(organize: true) }.buttonStyle(
            WarmButtonStyle(primary: true)
          ).disabled(
            model.saving || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Text(model.demo ? "演示使用固定合成响应，不代表真实模型效果。" : "原文先保存在本机。云端整理需在设置中配置并启用；手动整理随时可用。").font(
          TypeScale.body
        ).foregroundStyle(ink.opacity(0.68))
      }
    }
    HStack {
      Text("最近记录").font(TypeScale.body.weight(.semibold))
      Spacer()
      Toggle("只看待确认", isOn: $pendingOnly).toggleStyle(TextToggleStyle())
      TextField("搜索原文", text: $search).textFieldStyle(WarmFieldStyle()).frame(width: 200)
    }
    if entries.isEmpty {
      EmptyMessage(title: "从一条小事开始", detail: "写下最近的一次见面，或者一个不想忘记的偏好。你的记忆会在这里慢慢生长。")
    }
    ForEach(entries) { entry in
      EntryCard(entry: entry)
        .frame(maxWidth: 900, alignment: .leading).padding(.leading, 24)
        .transition(
          .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.97))))
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
  var proposals: [Proposal] {
    model.state.proposals.filter { $0.sourceID == entry.id && $0.status == .pending }
  }
  var task: TaskState? { model.state.tasks.last { $0.source_id == entry.id } }
  var body: some View {
    Card {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Text(entry.created.formatted(date: .abbreviated, time: .shortened)).font(TypeScale.body)
            .foregroundStyle(ink.opacity(0.68))
          if entry.demo { Text("演示").font(TypeScale.body).foregroundStyle(accent) }
          Spacer()
          Menu {
            Button("编辑原文") {
              text = entry.text
              editing = true
            }
            Button("删除原文及其记忆", role: .destructive) { deleting = true }
          } label: {
            Text("更多")
          }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 68)
        }
        Text(entry.text).font(TypeScale.body).lineSpacing(6).textSelection(.enabled)
        if let task {
          HStack {
            if task.phase.running { ProgressView().controlSize(.small) }
            Text(task.phase.label).font(TypeScale.body).foregroundStyle(
              task.phase == .failed ? accent : ink.opacity(0.68))
            if task.phase.running {
              TimelineView(.periodic(from: task.started_at, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(task.started_at)))
                Text(
                  seconds >= 25
                    ? "\(seconds) 秒 · 可取消或手动整理"
                    : seconds >= 8 ? "\(seconds) 秒 · 可以继续使用其他页面" : "\(seconds) 秒"
                ).font(TypeScale.body).foregroundStyle(ink.opacity(0.68))
              }
              Spacer()
              Button("取消整理") { model.cancel(entry) }
            }
          }
          if let error = task.error { Text(error).font(TypeScale.body).foregroundStyle(accent) }
          if !task.unprocessed.isEmpty {
            Text("还有未完整处理的内容：" + task.unprocessed.joined(separator: "；")).font(TypeScale.body)
              .foregroundStyle(accent)
          }
          if let decision = task.decisionStatus {
            DisclosureGroup("整理说明") {
              Text(decision).font(TypeScale.body).foregroundStyle(ink.opacity(0.68))
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
          Button("还有 \(proposals.count - 3) 条建议，展开查看") {
            withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.72)) {
              expanded = true
            }
          }
        }
        HStack {
          Button("手动整理") { manual = true }
          if task?.phase.running != true {
            Button(task == nil ? "整理这条记录" : "重新整理") { Task { await model.enqueue(entry) } }
          }
          Spacer()
        }.font(TypeScale.body)
        let approved = model.state.memories.filter {
          $0.sourceID == entry.id && $0.status == .active
        }
        if !approved.isEmpty {
          ForEach(approved) { m in
            HStack {
              Text("已记住：" + m.item.text).foregroundStyle(accent)
              Spacer()
              Button("撤销") {
                model.perform { try await $0.revoke(m.id, expected: m.revision, undo: true) }
              }
            }.font(TypeScale.body)
          }
        }
      }
    }.sheet(isPresented: $manual) { ManualMemorySheet(entry: entry) }
      .sheet(isPresented: $editing) {
        VStack(alignment: .leading, spacing: 20) {
          Text("编辑原文").font(TypeScale.title)
          Text("旧版本会保留为已确认记忆的历史依据。待确认建议将失效。").foregroundStyle(ink.opacity(0.68))
          TextEditor(text: $text).frame(height: 240)
          HStack {
            Button("取消") { editing = false }
            Spacer()
            Button("保存修改") {
              model.cancel(entry)
              model.perform {
                try await $0.editEntry(entry.id, revision: entry.revision, text: text)
              }
              editing = false
            }.disabled(text.isEmpty).buttonStyle(WarmButtonStyle(primary: true))
          }
        }.font(TypeScale.body).buttonStyle(WarmButtonStyle()).padding(32).frame(width: 560)
      }
      .confirmationDialog("删除这条原文及其关联记忆？后续检索将不再使用它。", isPresented: $deleting) {
        Button("删除", role: .destructive) {
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
      Text(proposal.item.kind == .plan ? "想安排：" + proposal.item.text : "记住：" + proposal.item.text)
        .font(TypeScale.body.weight(.medium))
      Text(
        "关联："
          + (model.state.people.first { $0.id == proposal.personID }?.name ?? proposal.item.subject
            ?? "尚未明确")
      ).font(TypeScale.body).foregroundStyle(ink.opacity(0.68))
      if let issue = proposal.issue { Text(issue).font(TypeScale.body).foregroundStyle(accent) }
      if let old = model.state.memories.first(where: { $0.id == proposal.replacementID }) {
        Text("替换：\(old.item.text) → \(proposal.item.text)").font(TypeScale.body).foregroundStyle(
          accent)
      }
      DisclosureGroup("查看依据") {
        VStack(alignment: .leading) {
          Text("“\(proposal.item.source_quote)”").textSelection(.enabled)
          Text(
            proposal.edited
              ? "表述由用户修改；引文是原始背景，不代表改写内容逐字出自原文。"
              : "\(proposal.item.evidence_mode.displayName) · \(proposal.item.time_text ?? "时间未注明")"
          ).font(TypeScale.body).foregroundStyle(ink.opacity(0.68))
        }
      }
      if editing {
        TextField("记忆内容", text: $value).textFieldStyle(WarmFieldStyle())
        PersonPicker(selection: $person)
        Picker("替换旧记忆（可选）", selection: $replacement) {
          Text("新增记忆").tag("")
          ForEach(model.state.activeMemories.filter { $0.personID == person.nilIfEmpty }) { m in
            Text(m.item.text).tag(m.id)
          }
        }
        Text("修改保存后仍需点击确认。请核对主体、否定、时间和条件。").font(TypeScale.body).foregroundStyle(ink.opacity(0.68))
        HStack {
          Button("取消修改") { editing = false }
          Button("保存修改") {
            var p = proposal
            p.item.text = value
            p.personID = person.nilIfEmpty
            p.item.subject = model.state.people.first { $0.id == person }?.name ?? "我"
            p.replacementID = replacement.nilIfEmpty
            p.replacementRevision = model.state.memories.first { $0.id == replacement }?.revision
            model.perform { try await $0.editProposal(p, expected: proposal.revision) }
            editing = false
          }.disabled(value.isEmpty)
        }
      } else {
        HStack {
          if proposal.item.kind == .plan {
            Button("去行程页补充时间") { model.page = "行程" }
          } else {
            Button("确认") {
              model.perform { _ = try await $0.confirm(proposal.id, revision: proposal.revision) }
            }.buttonStyle(WarmButtonStyle(primary: true)).disabled(proposal.issue != nil)
          }
          Button("修改") {
            value = proposal.item.text
            person = proposal.personID ?? ""
            replacement = proposal.replacementID ?? ""
            editing = true
          }
          Button("忽略") {
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
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("手动整理成记忆").font(TypeScale.title)
      Text(entry.text).lineLimit(5).foregroundStyle(ink.opacity(0.68))
      TextField("要记住的内容", text: $value, axis: .vertical).textFieldStyle(WarmFieldStyle())
      PersonPicker(selection: $person)
      Picker("内容", selection: $kind) {
        Text("偏好").tag(Kind.preference)
        Text("事实 / 描述").tag(Kind.fact)
        Text("共同经历").tag(Kind.experience)
        Text("目标").tag(Kind.goal)
        Text("备注").tag(Kind.note)
      }
      Picker("更新已有记忆", selection: $replacement) {
        Text("作为新记忆").tag("")
        ForEach(model.state.activeMemories.filter { $0.personID == person.nilIfEmpty }) { m in
          Text(m.item.text).tag(m.id)
        }
      }
      Text("这是你直接填写的内容。保存即确认；原始记录与修改来源会一起保留。").font(TypeScale.body).foregroundStyle(
        ink.opacity(0.68))
      HStack {
        Button("取消") { dismiss() }
        Spacer()
        Button(busy ? "正在保存…" : "确认保存") {
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
              model.error = error.localizedDescription
              busy = false
            }
          }
        }.buttonStyle(WarmButtonStyle(primary: true)).disabled(
          busy || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.count > 500
        )
      }
    }.font(TypeScale.body).buttonStyle(WarmButtonStyle()).disclosureGroupStyle(
      TextDisclosureStyle()
    ).padding(32).frame(width: 570).onAppear {
      value = replacementMemory?.item.text ?? String(entry.text.prefix(500))
      person = replacementMemory?.personID ?? entry.personID ?? ""
      replacement = replacementMemory?.id ?? ""
    }
  }
}
