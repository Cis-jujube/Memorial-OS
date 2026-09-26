import MemoriaCore
import SwiftUI

struct RecallView: View {
  @EnvironmentObject var model: AppModel
  var body: some View {
    PageTitle(title: L("想起一个人，问一件事"), subtitle: L("从你确认过的记忆中找答案。每条回答，都有可以回看的来处。"))
    Card {
      VStack(alignment: .leading, spacing: 16) {
        TextField(L("小林有什么爱好？周末约她怎么安排？"), text: $model.query, axis: .vertical).lineLimit(3...5)
          .textFieldStyle(WarmFieldStyle()).font(TypeScale.body).onSubmit { model.ask() }.onChange(
            of: model.query
          ) { _, _ in model.invalidateQuery() }
        HStack {
          PersonPicker(
            selection: Binding(
              get: { model.queryPerson },
              set: {
                model.invalidateQuery()
                model.queryPerson = $0
              }), label: L("正在聊谁"), queryScope: true)
          Spacer()
          Button(L("查找记忆")) { model.ask() }.buttonStyle(WarmButtonStyle(primary: true)).disabled(
            model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Text(L("⌘K 随时打开 · 普通资料查询在本机完成")).font(TypeScale.body).foregroundStyle(ink.opacity(0.68))
      }
    }
    if let result = model.recall {
      Card {
        VStack(alignment: .leading, spacing: 20) {
          HStack {
            Text(
              result.answer.status == "not_found"
                ? L("暂时没有相关记忆")
                : result.answer.status == "needs_clarification" ? L("先确认一下") : L("在记忆里找到了这些")
            ).font(TypeScale.body.weight(.medium))
            Spacer()
            if model.queryBusy {
              ProgressView().controlSize(.small)
              Button(L("取消")) { model.invalidateQuery() }
            }
          }
          if let question = result.answer.clarification {
            Text(L(question))
            Button(L("自己", "Myself")) {
              model.queryPerson = "__self"
              model.ask()
            }
            Button(L("添加人物", "Add a person")) { model.page = "人物" }
            ForEach(result.people) { p in
              Button(p.name + " · " + p.note) {
                model.queryPerson = p.id
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
            Text(L($0)).font(TypeScale.body).foregroundStyle(ink.opacity(0.68))
          }
          if !result.answer.suggestions.isEmpty {
            Divider()
            Text(L("可以怎么做")).font(TypeScale.body)
            ForEach(Array(result.answer.suggestions.enumerated()), id: \.offset) { _, suggestion in
              VStack(alignment: .leading, spacing: 8) {
                Text(suggestion.basis == "general" ? L("通用建议") : L("结合已确认记忆")).font(TypeScale.body)
                  .foregroundStyle(accent)
                Text(suggestion.text).lineSpacing(4)
                SourcesRow(ids: suggestion.source_ids)
              }
            }
          }
          HStack {
            if result.answer.status != "needs_clarification" {
              Button(L("补充记录")) {
                model.openCapture(
                  personID: result.people.count == 1 ? result.people[0].id : model.queryPerson)
              }
              Button(L("请模型整理建议")) { model.ask(synthesize: true) }.disabled(model.queryBusy)
            }
            if ["open_outing_editor", "lookup_current_information"].contains(
              result.answer.next_step)
            {
              Button(L("进一步安排 / 实时查询")) {
                model.outingPerson =
                  result.people.first?.id
                  ?? (model.queryPerson == "__self" ? "" : model.queryPerson)
                model.outingContext = model.query
                model.page = "行程"
              }
            }
          }
        }
      }
    } else {
      EmptyMessage(title: L("记忆会在需要时，派上用场"), detail: L("试试问某人的爱好、共同经历或相处建议。没有依据时，会直接告诉你资料不足。"))
    }
  }
}
struct SourcesRow: View {
  @EnvironmentObject var model: AppModel
  var ids: [String]
  var body: some View {
    if !ids.isEmpty {
      DisclosureGroup(L("查看来源")) {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(ids, id: \.self) { id in
            if let memory = model.state.activeMemories.first(where: { $0.id == id }) {
              HStack {
                Button(L("原文：") + String(memory.item.source_quote.prefix(45))) {
                  model.showSource(memory)
                }.buttonStyle(.link)
                Spacer()
                Button(L("纠正")) {
                  if model.openCapture(personID: memory.personID ?? "") {
                    model.notice = L(
                      "写下纠正内容，手动整理时选择替换“\(memory.item.text)”",
                      "Write a correction, then replace “\(memory.item.text)” in manual organization."
                    )
                  }
                }
              }
              Text(
                memory.userEdited
                  ? L("用户整理 / 修改", "Edited by you") + " · "
                    + displayDate(memory.created, includeTime: false)
                  : L("已确认记录", "Confirmed record") + " · " + memory.item.evidence_mode.displayName
              ).foregroundStyle(ink.opacity(0.68))
            } else {
              Text(L("来源已变化，请重新查询")).foregroundStyle(accent)
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
      PageTitle(title: L("重要的人"), subtitle: L("不必填满一张档案。那些相处中的小细节，就足够珍贵。 "))
      Spacer()
      Button(L("添加人物")) { adding = true }.buttonStyle(WarmButtonStyle(primary: true))
    }
    TextField(L("搜索姓名或备注"), text: $search).textFieldStyle(WarmFieldStyle())
    if model.state.people.isEmpty {
      EmptyMessage(title: L("先记住一个名字"), detail: L("为重要的人建立一处轻松的记录空间。姓名相同的人也可以分别建档。"))
    }
    HStack(alignment: .top, spacing: 20) {
      VStack(spacing: 8) {
        ForEach(
          model.state.people.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
              || $0.note.localizedCaseInsensitiveContains(search)
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
                Text(p.note.isEmpty ? L("还没有备注") : p.note).font(TypeScale.body).foregroundStyle(
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
              Button(L("编辑")) { editing = person }
              Button(L("删除"), role: .destructive) { deleting = true }
            }
            Text(person.note.isEmpty ? L("还没有备注") : person.note).foregroundStyle(ink.opacity(0.68))
            if !person.importantDate.isEmpty { Text(person.importantDate).font(TypeScale.body) }
            HStack {
              Button(L("问问关于 TA 的事")) {
                model.queryPerson = person.id
                model.query = L("有什么爱好？")
                model.page = "问一问"
                model.ask()
              }
              Button(L("记一件事")) {
                model.openCapture(personID: person.id)
              }
            }
            Divider()
            Text(L("已确认记忆")).font(TypeScale.body)
            let memories = model.state.activeMemories.filter { $0.personID == person.id }
            if memories.isEmpty {
              Text(L("还没有确认过的记忆。先记一件和 TA 有关的事吧。")).foregroundStyle(ink.opacity(0.68))
            }
            ForEach(memories) { m in
              VStack(alignment: .leading, spacing: 8) {
                Text(m.item.text)
                SourcesRow(ids: [m.id])
                HStack {
                  Button(L("纠正 / 更新")) {
                    if model.openCapture(personID: person.id) {
                      model.notice = L("记录新内容后，在手动整理中选择替换旧记忆")
                    }
                  }
                  Button(L("撤销这条记忆")) {
                    model.perform { try await $0.revoke(m.id, expected: m.revision) }
                  }
                }.font(TypeScale.body)
              }
              Divider()
            }
            DisclosureGroup(L("历史版本")) {
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
            Text(L("相关行程")).font(TypeScale.body)
            ForEach(
              model.state.outings.filter {
                $0.payload.participant_ids.contains(person.id) && !$0.cancelled
              }
            ) { o in Text(o.payload.title).font(TypeScale.body) }
          }
        }
      } else if !model.state.people.isEmpty {
        EmptyMessage(title: L("选一个人，看看近况"), detail: L("已确认的偏好、共同经历和行程会聚在一起。"))
      }
    }
    .sheet(isPresented: $adding) { PersonSheet(person: Person(name: ""), isNew: true) }
    .sheet(item: $editing) { PersonSheet(person: $0, isNew: false) }
    .confirmationDialog(L("删除人物后，其关联记忆将停止用于检索，原文保留。"), isPresented: $deleting) {
      Button(L("删除人物"), role: .destructive) {
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
  @ViewState private var busy = false
  @ViewState private var formError = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(isNew ? L("添加一个重要的人") : L("编辑人物")).font(TypeScale.title)
      TextField(L("姓名"), text: $person.name).textFieldStyle(WarmFieldStyle())
      TextField(L("简短备注，例如同学 / 同事"), text: $person.note).textFieldStyle(WarmFieldStyle())
      TextField(L("重要日期，例如生日 5 月 6 日"), text: $person.importantDate).textFieldStyle(
        WarmFieldStyle())
      if !formError.isEmpty { Text(formError).foregroundStyle(accent) }
      HStack {
        Button(L("取消")) { dismiss() }
        Spacer()
        Button(busy ? L("正在保存…") : L("保存")) {
          guard let store = model.store else { return }
          busy = true
          Task {
            defer { busy = false }
            do {
              try await store.savePerson(person, expected: isNew ? nil : person.revision)
              await model.refresh()
              dismiss()
            } catch { formError = L(error.localizedDescription) }
          }
        }.buttonStyle(WarmButtonStyle(primary: true)).disabled(
          busy || person.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.font(TypeScale.body).buttonStyle(WarmButtonStyle()).disclosureGroupStyle(
      TextDisclosureStyle()
    ).padding(32).frame(width: 490)
  }
}
