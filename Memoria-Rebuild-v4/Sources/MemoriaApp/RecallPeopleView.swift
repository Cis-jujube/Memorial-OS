import MemoriaCore
import SwiftUI

struct RecallView: View {
  @EnvironmentObject var model: AppModel
  var body: some View {
    PageTitle(title: "想起一个人，问一件事", subtitle: "从你确认过的记忆中找答案。每条回答，都有可以回看的来处。")
    Card {
      VStack(alignment: .leading, spacing: 16) {
        TextField("小林有什么爱好？周末约她怎么安排？", text: $model.query, axis: .vertical).lineLimit(3...5)
          .textFieldStyle(WarmFieldStyle()).font(TypeScale.body).onSubmit { model.ask() }.onChange(
            of: model.query
          ) { _, _ in model.invalidateQuery() }
        HStack {
          PersonPicker(selection: $model.queryPerson, label: "正在聊谁").onChange(of: model.queryPerson)
          { _, _ in model.invalidateQuery() }
          Spacer()
          Button("查找记忆") { model.ask() }.buttonStyle(WarmButtonStyle(primary: true)).disabled(
            model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Text("⌘K 随时打开 · 普通资料查询在本机完成").font(TypeScale.body).foregroundStyle(ink.opacity(0.68))
      }
    }
    if let result = model.recall {
      Card {
        VStack(alignment: .leading, spacing: 20) {
          HStack {
            Text(
              result.answer.status == "not_found"
                ? "暂时没有相关记忆" : result.answer.status == "needs_clarification" ? "先确认一下" : "在记忆里找到了这些"
            ).font(TypeScale.body.weight(.medium))
            Spacer()
            if model.queryBusy {
              ProgressView().controlSize(.small)
              Button("取消") { model.invalidateQuery() }
            }
          }
          if let question = result.answer.clarification {
            Text(question)
            ForEach(result.people) { p in
              Button(p.name + " · " + p.note) {
                model.queryPerson = p.id
                model.query = "有什么爱好？"
                model.ask()
              }
            }
          }
          ForEach(Array(result.answer.statements.enumerated()), id: \.offset) { _, statement in
            VStack(alignment: .leading, spacing: 8) {
              Text(statement.text).font(TypeScale.body).lineSpacing(4)
              SourcesRow(ids: statement.source_ids)
            }
          }
          ForEach(result.answer.missing_info, id: \.self) {
            Text($0).font(TypeScale.body).foregroundStyle(ink.opacity(0.68))
          }
          if !result.answer.suggestions.isEmpty {
            Divider()
            Text("可以怎么做").font(TypeScale.body)
            ForEach(Array(result.answer.suggestions.enumerated()), id: \.offset) { _, suggestion in
              VStack(alignment: .leading, spacing: 8) {
                Text(suggestion.basis == "general" ? "通用建议" : "结合已确认记忆").font(TypeScale.body)
                  .foregroundStyle(accent)
                Text(suggestion.text).lineSpacing(4)
                SourcesRow(ids: suggestion.source_ids)
              }
            }
          }
          HStack {
            Button("补充记录") {
              model.capturePerson = model.queryPerson
              model.page = "记录"
            }
            if result.answer.status != "needs_clarification" {
              Button("请模型整理建议") { model.ask(synthesize: true) }.disabled(model.queryBusy)
            }
            if ["open_outing_editor", "lookup_current_information"].contains(
              result.answer.next_step)
            {
              Button("进一步安排 / 实时查询") { model.page = "行程" }
            }
          }
        }
      }
    } else {
      EmptyMessage(title: "记忆会在需要时，派上用场", detail: "试试问某人的爱好、共同经历或相处建议。没有依据时，会直接告诉你资料不足。")
    }
  }
}
struct SourcesRow: View {
  @EnvironmentObject var model: AppModel
  var ids: [String]
  var body: some View {
    if !ids.isEmpty {
      DisclosureGroup("查看来源") {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(ids, id: \.self) { id in
            if let memory = model.state.activeMemories.first(where: { $0.id == id }) {
              HStack {
                Button("原文：" + String(memory.item.source_quote.prefix(45))) {
                  model.showSource(memory)
                }.buttonStyle(.link)
                Spacer()
                Button("纠正") {
                  model.draft = ""
                  model.capturePerson = memory.personID ?? ""
                  model.page = "记录"
                  model.notice = "写下纠正内容，手动整理时选择替换“\(memory.item.text)”"
                }
              }
              Text(
                memory.userEdited
                  ? "用户整理 / 修改 · \(memory.created.formatted(date: .abbreviated, time: .omitted))"
                  : "已确认记录 · \(memory.item.evidence_mode.displayName)"
              ).foregroundStyle(ink.opacity(0.68))
            } else {
              Text("来源已变化，请重新查询").foregroundStyle(accent)
            }
          }
        }.font(TypeScale.body)
      }.font(TypeScale.body)
    }
  }
}
struct PeopleView: View {
  @EnvironmentObject var model: AppModel
  @ViewState private var selected = ""
  @ViewState private var editing: Person?
  @ViewState private var adding = false
  @ViewState private var search = ""
  @ViewState private var deleting = false
  var person: Person? { model.state.people.first { $0.id == selected } }
  var body: some View {
    HStack {
      PageTitle(title: "重要的人", subtitle: "不必填满一张档案。那些相处中的小细节，就足够珍贵。 ")
      Spacer()
      Button("添加人物") { adding = true }.buttonStyle(WarmButtonStyle(primary: true))
    }
    TextField("搜索姓名或备注", text: $search).textFieldStyle(WarmFieldStyle())
    if model.state.people.isEmpty {
      EmptyMessage(title: "先记住一个名字", detail: "为重要的人建立一处轻松的记录空间。姓名相同的人也可以分别建档。")
    }
    HStack(alignment: .top, spacing: 20) {
      VStack(spacing: 8) {
        ForEach(
          model.state.people.filter {
            search.isEmpty || $0.name.contains(search) || $0.note.contains(search)
          }
        ) { p in
          Button {
            selected = p.id
          } label: {
            HStack {
              Text(String(p.name.prefix(1))).font(TypeScale.body).frame(width: 40, height: 40)
                .background(accent.opacity(0.10), in: Circle())
              VStack(alignment: .leading, spacing: 4) {
                Text(p.name).font(TypeScale.body)
                Text(p.note.isEmpty ? "还没有备注" : p.note).font(TypeScale.body).foregroundStyle(
                  ink.opacity(0.68)
                ).lineLimit(2)
              }
              Spacer()
            }.padding(12).frame(maxWidth: .infinity).background(
              p.id == selected ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 12))
          }.buttonStyle(.plain)
        }
      }.frame(width: 235)
      if let person {
        Card {
          VStack(alignment: .leading, spacing: 18) {
            HStack {
              Text(person.name).font(TypeScale.title)
              Spacer()
              Button("编辑") { editing = person }
              Button("删除", role: .destructive) { deleting = true }
            }
            Text(person.note.isEmpty ? "还没有备注" : person.note).foregroundStyle(ink.opacity(0.68))
            if !person.importantDate.isEmpty { Text(person.importantDate).font(TypeScale.body) }
            HStack {
              Button("问问关于 TA 的事") {
                model.queryPerson = person.id
                model.query = "有什么爱好？"
                model.page = "问一问"
                model.ask()
              }
              Button("记一件事") {
                model.capturePerson = person.id
                model.page = "记录"
              }
            }
            Divider()
            Text("已确认记忆").font(TypeScale.body)
            let memories = model.state.activeMemories.filter { $0.personID == person.id }
            if memories.isEmpty {
              Text("还没有确认过的记忆。先记一件和 TA 有关的事吧。").foregroundStyle(ink.opacity(0.68))
            }
            ForEach(memories) { m in
              VStack(alignment: .leading, spacing: 8) {
                Text(m.item.text)
                SourcesRow(ids: [m.id])
                HStack {
                  Button("纠正 / 更新") {
                    model.capturePerson = person.id
                    model.page = "记录"
                    model.notice = "记录新内容后，在手动整理中选择替换旧记忆"
                  }
                  Button("撤销这条记忆") {
                    model.perform { try await $0.revoke(m.id, expected: m.revision) }
                  }
                }.font(TypeScale.body)
              }
              Divider()
            }
            DisclosureGroup("历史版本") {
              ForEach(
                model.state.memories.filter { $0.personID == person.id && $0.status != .active }
              ) { m in
                HStack {
                  Text(m.item.text)
                  Spacer()
                  Text(m.status.displayName).foregroundStyle(ink.opacity(0.68))
                }.font(TypeScale.body)
              }
            }
            Text("相关行程").font(TypeScale.body)
            ForEach(
              model.state.outings.filter {
                $0.payload.participant_ids.contains(person.id) && !$0.cancelled
              }
            ) { o in Text(o.payload.title).font(TypeScale.body) }
          }
        }
      } else if !model.state.people.isEmpty {
        EmptyMessage(title: "选一个人，看看近况", detail: "已确认的偏好、共同经历和行程会聚在一起。")
      }
    }
    .sheet(isPresented: $adding) { PersonSheet(person: Person(name: ""), isNew: true) }
    .sheet(item: $editing) { PersonSheet(person: $0, isNew: false) }
    .confirmationDialog("删除人物后，其关联记忆将停止用于检索，原文保留。", isPresented: $deleting) {
      Button("删除人物", role: .destructive) {
        let id = selected
        model.perform { try await $0.deletePerson(id) }
        selected = ""
      }
    }
  }
}
struct PersonSheet: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.dismiss) var dismiss
  @ViewState var person: Person
  var isNew: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(isNew ? "添加一个重要的人" : "编辑人物").font(TypeScale.title)
      TextField("姓名", text: $person.name).textFieldStyle(WarmFieldStyle())
      TextField("简短备注，例如同学 / 同事", text: $person.note).textFieldStyle(WarmFieldStyle())
      TextField("重要日期，例如生日 5 月 6 日", text: $person.importantDate).textFieldStyle(WarmFieldStyle())
      HStack {
        Button("取消") { dismiss() }
        Spacer()
        Button("保存") {
          guard let store = model.store else { return }
          Task {
            do {
              try await store.savePerson(person, expected: isNew ? nil : person.revision)
              await model.refresh()
              dismiss()
            } catch { model.error = error.localizedDescription }
          }
        }.buttonStyle(WarmButtonStyle(primary: true)).disabled(
          person.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.font(TypeScale.body).buttonStyle(WarmButtonStyle()).disclosureGroupStyle(
      TextDisclosureStyle()
    ).padding(32).frame(width: 490)
  }
}
