import MemoriaCore
import SwiftUI

struct OutingsView: View {
  @EnvironmentObject var model: AppModel
  @ViewState private var creating = false
  @ViewState private var editing: Outing?
  @ViewState private var publicQuery = ""
  @ViewState private var date = Date()
  @ViewState private var person = ""
  @ViewState private var budget = ""
  @ViewState private var chosen: Set<String> = []
  @ViewState private var cancellation: Outing?
  var body: some View {
    HStack {
      PageTitle(title: "把期待，变成一次见面", subtitle: "从记忆出发，用实际信息补全计划。保存行程后，仍由你决定如何邀请。 ")
      Spacer()
      Button("手动新建") {
        model.plan = nil
        creating = true
      }.buttonStyle(WarmButtonStyle(primary: true))
    }
    Card {
      VStack(alignment: .leading, spacing: 16) {
        Text("一起去哪儿？").font(TypeScale.body)
        TextField("公共查询关键词，例如：昆山 安静 展览", text: $publicQuery).textFieldStyle(WarmFieldStyle())
        Text("地图与网页只发送这里的公共关键词，不附加姓名或私人原文。").font(TypeScale.body).foregroundStyle(ink.opacity(0.68))
        HStack {
          PersonPicker(selection: $person, label: "与谁同行")
          DatePicker("日期", selection: $date, displayedComponents: .date)
        }
        HStack {
          TextField("人民币总预算（所有参与者）", text: $budget).textFieldStyle(WarmFieldStyle())
          Spacer()
          Button("查询地点与天气") { query(agent: false) }.disabled(
            model.toolBusy || publicQuery.isEmpty
              || (!budget.isEmpty && (Double(budget) == nil || Double(budget)! < 0)))
          Button("让 Agent 规划") { query(agent: true) }.disabled(
            model.toolBusy || publicQuery.isEmpty
              || (!budget.isEmpty && (Double(budget) == nil || Double(budget)! < 0)))
        }
        if model.toolBusy {
          HStack {
            ProgressView().controlSize(.small)
            Text("正在查询，可以切换页面").font(TypeScale.body)
            Spacer()
            Button("取消查询") { model.cancelTools() }
          }
        }
        ForEach(Array(model.toolReceipts.enumerated()), id: \.offset) { _, receipt in
          DisclosureGroup("\(receipt.displayName) · \(receipt.status == "ok" ? "已返回" : "未完成")") {
            VStack(alignment: .leading, spacing: 7) {
              if let error = receipt.error { Text(error).foregroundStyle(accent) }
              Text(receipt.fetchedAt.formatted(date: .abbreviated, time: .shortened))
              if receipt.name == "get_weather", receipt.status == "ok" {
                Text(receipt.weatherDescription)
              }
              ForEach(receipt.sources, id: \.self) { source in
                if let url = URL(string: source) { Link("查看实际来源", destination: url) }
              }
            }.font(TypeScale.body)
          }.font(TypeScale.body)
        }
        ForEach(model.places) { place in
          HStack(alignment: .top) {
            Toggle(
              isOn: Binding(
                get: { chosen.contains(place.id) },
                set: { if $0 { chosen.insert(place.id) } else { chosen.remove(place.id) } })
            ) {
              VStack(alignment: .leading, spacing: 5) {
                Text(place.name)
                Text(place.address).font(TypeScale.body).foregroundStyle(ink.opacity(0.68))
                Text("票价与营业时间待核实").font(TypeScale.body).foregroundStyle(accent)
              }
            }.toggleStyle(TextToggleStyle())
            Spacer()
            Link("地图", destination: URL(string: place.url)!)
          }
        }
        if !chosen.isEmpty {
          Button("用所选地点建立草案") {
            let stops = model.places.filter { chosen.contains($0.id) }.map { Stop(place: $0) }
            model.plan = OutingPlan(
              stops: stops,
              memoryIDs: model.state.activeMemories.filter { $0.personID == person.nilIfEmpty }.map(
                \.id), budget: Double(budget), notes: "费用、营业时间与交通耗时尚待核实")
            creating = true
          }.disabled(chosen.count > 2)
        }
        if let plan = model.plan {
          VStack(alignment: .leading, spacing: 10) {
            Text("方案草案 · \(plan.stops.count) 站").font(TypeScale.body)
            Text(plan.notes)
            ForEach(plan.stops) { stop in Text(stop.place.name) }
            Text("费用未知，无法保证满足预算。").font(TypeScale.body).foregroundStyle(accent)
            Button("检查时间并保存") { creating = true }
          }
        }
      }
    }
    Text("近期与待定行程").font(TypeScale.body.weight(.semibold))
    if model.state.outings.isEmpty {
      EmptyMessage(title: "留一点时间，给重要的人", detail: "没有具体时间也可以先保存草案。提醒只会在你明确选择时安排。")
    }
    ForEach(
      model.state.outings.filter { !$0.cancelled }.sorted {
        ($0.payload.start_at ?? "z") < ($1.payload.start_at ?? "z")
      }
    ) { outing in
      Card {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text(outing.payload.title).font(TypeScale.body)
            Spacer()
            Text(
              outing.payload.start_at == nil || outing.payload.end_at == nil ? "草案 · 时间待定" : "已确认行程"
            ).font(TypeScale.body).foregroundStyle(accent)
          }
          Text(
            outing.payload.start_at.flatMap(parseDate)?.formatted(
              date: .abbreviated, time: .shortened) ?? "尚未确定时间"
          ).foregroundStyle(ink.opacity(0.68))
          if let plan = outing.plan {
            ForEach(plan.stops) { stop in
              Link(stop.place.name, destination: URL(string: stop.place.url)!)
            }
          }
          Text(
            "费用：" + (outing.payload.estimated_total_cost.map { "人民币 \($0) 元（总额估计）" } ?? "未知")
              + " · " + outing.notificationStatus
          ).font(TypeScale.body)
          HStack {
            Button("编辑") { editing = outing }
            Button("记录反馈") {
              model.captureOuting = outing.id
              model.capturePerson = outing.payload.participant_ids.first ?? ""
              model.draft = ""
              model.page = "记录"
              model.notice = "反馈保存后，确认相关偏好更新即可影响下一次建议"
            }
            Button("重试提醒") {
              model.perform { store in
                let status = await Notifications.sync(outing)
                try await store.notification(outing.id, revision: outing.revision, status: status)
              }
            }
            Button("取消行程", role: .destructive) { cancellation = outing }
          }
        }
      }
    }
    .sheet(isPresented: $creating) {
      OutingSheet(outing: nil, plan: model.plan, participant: person)
    }
    .sheet(item: $editing) {
      OutingSheet(outing: $0, plan: $0.plan, participant: $0.payload.participant_ids.first ?? "")
    }
    .confirmationDialog(
      "确认取消“\(cancellation?.payload.title ?? "")”？",
      isPresented: Binding(get: { cancellation != nil }, set: { if !$0 { cancellation = nil } })
    ) {
      Button("确认取消行程", role: .destructive) {
        if let o = cancellation {
          var action = ActionDraft(payload: nil)
          action.operation = "cancel"
          action.target_id = o.id
          action.expected_target_revision = o.revision
          model.saveOuting(action, plan: nil)
        }
        cancellation = nil
      }
    }
  }
  func query(agent: Bool) {
    chosen = []
    model.lookup(
      publicQuery: publicQuery, date: date, budget: Double(budget), personID: person.nilIfEmpty,
      agent: agent)
  }
}
struct OutingSheet: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.dismiss) var dismiss
  var outing: Outing?
  var plan: OutingPlan?
  var participant: String
  @ViewState private var title = ""
  @ViewState private var participants: Set<String> = []
  @ViewState private var editablePlan: OutingPlan?
  @ViewState private var timed = false
  @ViewState private var start = Date().addingTimeInterval(3600)
  @ViewState private var end = Date().addingTimeInterval(7200)
  @ViewState private var location = ""
  @ViewState private var cost = ""
  @ViewState private var notes = ""
  @ViewState private var remind = false
  @ViewState private var reminder = Date().addingTimeInterval(1800)
  @ViewState private var busy = false
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(outing == nil ? "确认这次安排" : "修改行程").font(TypeScale.title)
      TextField("活动名称", text: $title).textFieldStyle(WarmFieldStyle())
      DisclosureGroup("参与者（已选 \(participants.count) 位朋友，另包含自己）") {
        ForEach(model.state.people) { p in
          Toggle(
            p.name + (p.note.isEmpty ? "" : " · " + p.note),
            isOn: Binding(
              get: { participants.contains(p.id) },
              set: { if $0 { participants.insert(p.id) } else { participants.remove(p.id) } })
          ).toggleStyle(TextToggleStyle())
        }
      }
      TextField("地点", text: $location).textFieldStyle(WarmFieldStyle()).disabled(
        editablePlan != nil)
      Toggle("已确定开始和结束时间", isOn: $timed)
      if timed {
        DatePicker("开始", selection: $start)
        DatePicker("结束", selection: $end)
        Toggle("设置本机通知", isOn: $remind)
        if remind { DatePicker("提醒时刻", selection: $reminder) }
      }
      TextField("预计总费用（人民币；未知留空）", text: $cost).textFieldStyle(WarmFieldStyle())
      TextField("备注与尚未确认事项", text: $notes, axis: .vertical).textFieldStyle(WarmFieldStyle())
      if let plan = editablePlan {
        ForEach(Array(plan.stops.enumerated()), id: \.element.id) { index, stop in
          HStack {
            Text(stop.place.name)
            Spacer()
            Button("上移") { moveStop(index, -1) }.disabled(index == 0)
            Button("下移") { moveStop(index, 1) }.disabled(index == plan.stops.count - 1)
          }
        }
        Text("完整地点列表与来源会一并保存。费用和营业状态仍需核实。").font(TypeScale.body).foregroundStyle(ink.opacity(0.68))
      }
      HStack {
        Button("取消") { dismiss() }
        Spacer()
        Button(busy ? "正在保存…" : timed ? "确认保存行程" : "保存为草案") { save() }.buttonStyle(
          WarmButtonStyle(primary: true)
        ).disabled(
          busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (!cost.isEmpty && Double(cost) == nil))
      }
    }.font(TypeScale.body).buttonStyle(WarmButtonStyle()).disclosureGroupStyle(
      TextDisclosureStyle()
    ).padding(32).frame(width: 600).onAppear {
      participants = Set(
        outing?.payload.participant_ids ?? (participant.isEmpty ? [] : [participant]))
      editablePlan = plan
      title = outing?.payload.title ?? plan?.stops.first?.place.name ?? ""
      location = outing?.payload.location_name ?? plan?.stops.first?.place.name ?? ""
      notes = outing?.payload.notes ?? plan?.notes ?? ""
      if let p = outing?.payload {
        timed = p.start_at != nil && p.end_at != nil
        start = p.start_at.flatMap(parseDate) ?? start
        end = p.end_at.flatMap(parseDate) ?? end
        cost = p.estimated_total_cost.map { String($0) } ?? ""
        remind = p.remind_at != nil
        reminder = p.remind_at.flatMap(parseDate) ?? reminder
      }
    }
  }
  func moveStop(_ index: Int, _ direction: Int) {
    guard var plan = editablePlan, plan.stops.indices.contains(index + direction) else { return }
    plan.stops.swapAt(index, index + direction)
    location = plan.stops.first?.place.name ?? ""
    plan.id = uid()
    plan.revision = 1
    editablePlan = plan
  }
  func save() {
    guard let store = model.store else { return }
    busy = true
    let payload = OutingPayload(
      title: title, start: timed ? start : nil, end: timed ? end : nil,
      location: location.nilIfEmpty, people: participants.sorted(), cost: Double(cost),
      notes: notes.nilIfEmpty, reminder: timed && remind ? reminder : nil)
    let plan = editablePlan
    var action = ActionDraft(payload: payload)
    if let outing {
      action.operation = "update"
      action.target_id = outing.id
      action.expected_target_revision = outing.revision
    }
    action.proposal_id = plan?.id
    action.proposal_revision = plan?.revision
    Task {
      do {
        if let plan, !model.state.plans.contains(where: { $0.id == plan.id }) {
          try await store.savePlan(plan)
        }
        let id = try await store.execute(action)
        await model.refresh()
        dismiss()
        if let saved = model.state.outings.first(where: { $0.id == id }) {
          let status = await Notifications.sync(saved)
          try await store.notification(id, revision: saved.revision, status: status)
          await model.refresh()
        }
      } catch {
        model.error = error.localizedDescription
        busy = false
      }
    }
  }
}
struct SettingsView: View {
  @EnvironmentObject var model: AppModel
  @ViewState private var key = ""
  @ViewState private var jevKey = ""
  @ViewState private var braveKey = ""
  var body: some View {
    PageTitle(title: "按照你的方式使用", subtitle: "记忆属于你。模型可以更换，已经确认的资料会一直留在这里。")
    Card {
      VStack(alignment: .leading, spacing: 18) {
        Text("模型与云端整理").font(TypeScale.body)
        Picker("提供方", selection: $model.config.provider) {
          ForEach(Provider.allCases) { Text($0.rawValue).tag($0) }
        }.onChange(of: model.config.provider) { _, provider in
          model.config.model = provider.suggestedModel
          model.config.nativeSchema = false
          model.config.toolsDeclared = false
          model.configStatus = "能力尚未验证"
          key = ""
        }
        TextField("模型 ID（可按账户可用模型修改）", text: $model.config.model).textFieldStyle(WarmFieldStyle())
        SecureField("API Key（留空保留已存密钥）", text: $key).textFieldStyle(WarmFieldStyle())
        Toggle("允许将本条原文和必要上下文发送给所选模型", isOn: $model.config.cloudConsent)
        Toggle("当前模型支持工具调用（配置声明，非验证结果）", isOn: $model.config.toolsDeclared)
        Toggle("使用原生 Schema（仅支持对应接口的模型）", isOn: $model.config.nativeSchema)
        Text("默认使用 JSON 输出与本地完整校验。模型可用性取决于你的账户；不会自动切换提供方。").font(TypeScale.body).foregroundStyle(
          ink.opacity(0.68))
        HStack {
          Button("保存配置与密钥") {
            model.saveConfig(key: key, jevKey: jevKey, braveKey: braveKey)
            key = ""
            jevKey = ""
            braveKey = ""
          }
          Button("测试文本连接") { model.testConnection() }
          Text(model.configStatus).font(TypeScale.body).foregroundStyle(ink.opacity(0.68))
        }
      }
    }
    Card {
      VStack(alignment: .leading, spacing: 16) {
        Text("可选能力").font(TypeScale.body)
        Toggle("启用 Jev 语义判断辅助", isOn: $model.config.jevEnabled)
        Text("启用后会发送必要原文、候选与少量相关记忆。判断不会自动确认记忆，失败时保留人工处理。").font(TypeScale.body).foregroundStyle(
          ink.opacity(0.68))
        TextField("Jev 模型", text: $model.config.jevModel).textFieldStyle(WarmFieldStyle())
        SecureField("Jev 独立 Key", text: $jevKey).textFieldStyle(WarmFieldStyle())
        SecureField("Brave Search Key（可选）", text: $braveKey).textFieldStyle(WarmFieldStyle())
        Text("未配置网页搜索时仍可查询地图与天气。输入后点击上方“保存配置与密钥”。").font(TypeScale.body).foregroundStyle(
          ink.opacity(0.68))
      }
    }
    Card {
      VStack(alignment: .leading, spacing: 16) {
        Text("数据与演示").font(TypeScale.body)
        HStack {
          Button("导出备份") { model.exportBackup() }
          Button("从备份恢复…") { model.restoreBackup() }
          Button("在 Finder 中查看数据") { NSWorkspace.shared.open(model.directory) }
        }
        Text("恢复前先预览内容并备份当前状态。备份不包含 API Key。").font(TypeScale.body).foregroundStyle(
          ink.opacity(0.68))
        Divider()
        Toggle("演示模式（固定合成响应）", isOn: $model.demo)
        Button("准备虚构人物与演示输入") { model.loadDemo() }
        Text("只添加虚构人物并填入输入框；点击保存后才创建记录。演示不冒充实际模型或联网结果。").font(TypeScale.body).foregroundStyle(
          ink.opacity(0.68))
      }
    }
  }
}
