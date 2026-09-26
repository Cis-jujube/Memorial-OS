import MemoriaCore
import SwiftUI

struct OutingsView: View {
  @EnvironmentObject var model: AppModel
  @ViewState private var creating = false
  @ViewState private var editing: Outing?
  @ViewState private var cancellation: Outing?
  var budgetAmount: Double? {
    Double(model.outingBudget.trimmingCharacters(in: .whitespacesAndNewlines))
  }
  var validBudget: Bool {
    let value = model.outingBudget.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return true }
    guard let amount = budgetAmount else { return false }
    return amount.isFinite && amount >= 0
  }
  var activeOutings: [Outing] {
    let now = Date()
    func rank(_ outing: Outing) -> Int {
      guard let start = outing.payload.start_at.flatMap(parseDate) else { return 1 }
      return start >= now ? 0 : 2
    }
    return model.state.outings.filter { !$0.cancelled }.sorted {
      let left = rank($0)
      let right = rank($1)
      if left != right { return left < right }
      if left == 2 { return ($0.payload.start_at ?? "") > ($1.payload.start_at ?? "") }
      return ($0.payload.start_at ?? "") < ($1.payload.start_at ?? "")
    }
  }
  var body: some View {
    HStack {
      PageTitle(title: L("把期待，变成一次见面"), subtitle: L("从记忆出发，用实际信息补全计划。保存行程后，仍由你决定如何邀请。 "))
      Spacer()
      Button(L("手动新建")) {
        model.plan = nil
        creating = true
      }.buttonStyle(WarmButtonStyle(primary: true))
    }
    if !model.outingContext.isEmpty {
      Text(model.outingContext).foregroundStyle(ink.opacity(0.68))
    }
    Card {
      VStack(alignment: .leading, spacing: 16) {
        Text(L("一起去哪儿？")).font(TypeScale.body)
        TextField(L("公共查询关键词，例如：昆山 安静 展览"), text: $model.outingPublicQuery).textFieldStyle(
          WarmFieldStyle())
        Text(L("地图与网页只发送这里的公共关键词，不附加姓名或私人原文。")).font(TypeScale.body).foregroundStyle(
          ink.opacity(0.68))
        HStack {
          PersonPicker(selection: $model.outingPerson, label: L("与谁同行"))
          DatePicker(L("日期"), selection: $model.outingDate, displayedComponents: .date)
        }
        HStack {
          TextField(L("人民币总预算（所有参与者）"), text: $model.outingBudget).textFieldStyle(WarmFieldStyle())
          Spacer()
          Button(L("查询地点与天气")) { query(agent: false) }.disabled(
            model.toolBusy || model.outingPublicQuery.isEmpty
              || !validBudget
          )
          Button(L("让 Agent 规划")) { query(agent: true) }.disabled(
            model.toolBusy || model.outingPublicQuery.isEmpty
              || !validBudget
          )
        }
        if !validBudget {
          Text(L("预算需为有限的非负数", "Budget must be a finite nonnegative amount."))
            .foregroundStyle(accent)
        }
        if model.toolBusy {
          HStack {
            ProgressView().controlSize(.small)
            Text(L("正在查询，可以切换页面")).font(TypeScale.body)
            Spacer()
            Button(L("取消查询")) { model.cancelTools() }
          }
        }
        ForEach(Array(model.toolReceipts.enumerated()), id: \.offset) { _, receipt in
          let receiptTitle =
            (receipt.data["place_name"] as? String).map {
              receipt.displayName + " · " + $0
            } ?? receipt.displayName
          DisclosureGroup(
            "\(receiptTitle) · \(receipt.status == "ok" ? L("已返回", "Returned") : L("未完成", "Incomplete"))"
          ) {
            VStack(alignment: .leading, spacing: 7) {
              if let error = receipt.error { Text(L(error)).foregroundStyle(accent) }
              Text(displayDate(receipt.fetchedAt))
              if receipt.name == "get_weather", receipt.status == "ok" {
                if let placeName = receipt.data["place_name"] as? String {
                  if receipt.data["requested_place"] as? Bool != true {
                    Text(
                      L(
                        "天气地点：\(placeName)（搜索结果首项）",
                        "Weather for \(placeName) (first search result)"))
                  } else {
                    Text(L("天气地点：\(placeName)（指定地点）", "Weather for \(placeName) (specified place)"))
                  }
                }
                if let forecastDate = receipt.data["forecast_date"] as? String {
                  Text(L("预报日期：\(forecastDate)", "Forecast date: \(forecastDate)"))
                }
                Text(receipt.weatherDescription)
              }
              ForEach(receipt.sources, id: \.self) { source in
                if let url = URL(string: source) { Link(L("查看实际来源"), destination: url) }
              }
            }.font(TypeScale.body)
          }.font(TypeScale.body)
        }
        if !model.toolBusy && model.places.isEmpty
          && model.toolReceipts.contains(where: { $0.name == "search_places" && $0.status == "ok" })
        {
          EmptyMessage(
            title: L("没有找到地点", "No places found"),
            detail: L(
              "试试更具体的区域或地点名称，或直接建立手动行程草案。",
              "Try a more specific area or place name, or create a manual outing draft."))
        }
        ForEach(model.places) { place in
          HStack(alignment: .top) {
            Toggle(
              isOn: Binding(
                get: { model.outingChosen.contains(place.id) },
                set: {
                  if $0 {
                    model.outingChosen.insert(place.id)
                  } else {
                    model.outingChosen.remove(place.id)
                  }
                  model.toolReceipts.removeAll { $0.name == "get_weather" }
                })
            ) {
              VStack(alignment: .leading, spacing: 5) {
                Text(place.name)
                Text(place.address).font(TypeScale.body).foregroundStyle(ink.opacity(0.68))
                Text(L("票价与营业时间待核实")).font(TypeScale.body).foregroundStyle(accent)
                if let forecast = model.toolReceipts.last(where: {
                  $0.name == "get_weather" && $0.status == "ok"
                    && $0.data["place_id"] as? String == place.id
                }) {
                  if let forecastDate = forecast.data["forecast_date"] as? String {
                    Text(L("\(forecastDate) 天气", "Weather on \(forecastDate)"))
                      .foregroundStyle(accent)
                  }
                  Text(forecast.weatherDescription).foregroundStyle(ink.opacity(0.68))
                }
              }
            }.toggleStyle(TextToggleStyle(selection: true)).disabled(model.toolBusy)
            Spacer()
            if model.outingChosen.contains(place.id) {
              Button(L("查询此地天气", "Weather here")) {
                model.lookupWeather(for: place.id)
              }.disabled(model.toolBusy)
            }
            Link(L("地图"), destination: URL(string: place.url)!)
          }
        }
        if !model.places.isEmpty {
          Text(L("最多选择两站，给行程留一点余裕。", "Choose up to two stops and leave time between them."))
            .foregroundStyle(ink.opacity(0.68))
        }
        if model.outingChosen.count > 2 {
          Text(L("请减少到两站后建立草案。", "Select no more than two stops to create a draft."))
            .foregroundStyle(accent)
        }
        if !model.outingChosen.isEmpty {
          Button(L("用所选地点建立草案")) {
            let stops = model.places.filter { model.outingChosen.contains($0.id) }.map {
              Stop(place: $0)
            }
            model.plan = OutingPlan(
              stops: stops,
              memoryIDs: model.state.activeMemories.filter {
                $0.personID == model.outingPerson.nilIfEmpty
              }.map(
                \.id), budget: budgetAmount, notes: L("费用、营业时间与交通耗时尚待核实"))
            creating = true
          }.disabled(model.outingChosen.count > 2 || !validBudget)
        }
        if let plan = model.plan {
          VStack(alignment: .leading, spacing: 10) {
            Text(L("方案草案 · \(plan.stops.count) 站", "Draft · \(plan.stops.count) stops")).font(
              TypeScale.body)
            Text(plan.notes)
            ForEach(plan.stops) { stop in Text(stop.place.name) }
            Text(L("费用未知，无法保证满足预算。")).font(TypeScale.body).foregroundStyle(accent)
            Button(L("检查时间并保存")) { creating = true }
          }
        }
      }
    }
    Text(L("行程与草案", "Outings and drafts")).font(TypeScale.body.weight(.semibold))
    if activeOutings.isEmpty {
      EmptyMessage(title: L("留一点时间，给重要的人"), detail: L("没有具体时间也可以先保存草案。提醒只会在你明确选择时安排。"))
    }
    ForEach(activeOutings) { outing in
      Card {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text(outing.payload.title).font(TypeScale.body)
            Spacer()
            Text(
              outing.payload.start_at == nil || outing.payload.end_at == nil
                ? L("草案 · 时间待定") : L("已确认行程")
            ).font(TypeScale.body).foregroundStyle(accent)
          }
          Text(
            outing.payload.start_at.flatMap(parseDate).map { displayDate($0) } ?? L("尚未确定时间")
          ).foregroundStyle(ink.opacity(0.68))
          if let plan = outing.plan {
            ForEach(plan.stops) { stop in
              Link(stop.place.name, destination: URL(string: stop.place.url)!)
            }
          }
          Text(
            L("费用：")
              + (outing.payload.estimated_total_cost.map {
                L("人民币 \($0) 元（总额估计）", "CNY \($0) (estimated total)")
              } ?? L("未知"))
              + " · " + displayNotificationStatus(outing.notificationStatus)
          ).font(TypeScale.body)
          HStack {
            Button(L("编辑")) { editing = outing }
            Button(L("记录反馈")) {
              if model.openCapture(
                personID: outing.payload.participant_ids.first ?? "", outingID: outing.id)
              {
                model.notice = L("反馈保存后，确认相关偏好更新即可影响下一次建议")
              }
            }
            Button(L("重试提醒")) {
              model.perform { store in
                let status = await Notifications.sync(outing)
                try await store.notification(outing.id, revision: outing.revision, status: status)
              }
            }
            Button(L("取消行程"), role: .destructive) { cancellation = outing }
          }
        }
      }
    }
    .sheet(isPresented: $creating) {
      OutingSheet(outing: nil, plan: model.plan, participant: model.outingPerson)
    }
    .sheet(item: $editing) {
      OutingSheet(outing: $0, plan: $0.plan, participant: $0.payload.participant_ids.first ?? "")
    }
    .confirmationDialog(
      L("确认取消行程？", "Cancel this outing?"),
      isPresented: Binding(get: { cancellation != nil }, set: { if !$0 { cancellation = nil } })
    ) {
      Button(L("确认取消行程"), role: .destructive) {
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
    guard validBudget else { return }
    model.outingChosen = []
    model.lookup(
      publicQuery: model.outingPublicQuery, date: model.outingDate,
      budget: budgetAmount, personID: model.outingPerson.nilIfEmpty,
      agent: agent)
  }
}
struct OutingSheet: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.dismiss) var dismiss
  var outing: Outing?
  var plan: OutingPlan?
  var participant: String
  var sourceProposal: Proposal? = nil
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
  @ViewState private var formError = ""
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text(outing == nil ? L("确认这次安排") : L("修改行程")).font(TypeScale.title)
        VStack(alignment: .leading, spacing: 7) {
          Text(L("活动名称", "Outing name"))
          TextField(L("活动名称"), text: $title).textFieldStyle(WarmFieldStyle())
        }
        DisclosureGroup(
          L(
            "参与者（已选 \(participants.count) 位朋友，另包含自己）",
            "Participants (you + \(participants.count) selected)")
        ) {
          ForEach(model.state.people) { p in
            Toggle(
              p.name + (p.note.isEmpty ? "" : " · " + p.note),
              isOn: Binding(
                get: { participants.contains(p.id) },
                set: { if $0 { participants.insert(p.id) } else { participants.remove(p.id) } })
            ).toggleStyle(TextToggleStyle(selection: true))
          }
        }
        VStack(alignment: .leading, spacing: 7) {
          Text(L("地点", "Location"))
          TextField(L("地点"), text: $location).textFieldStyle(WarmFieldStyle()).disabled(
            editablePlan != nil)
        }
        Toggle(L("已确定开始和结束时间"), isOn: $timed)
        if timed {
          DatePicker(L("开始"), selection: $start)
          DatePicker(L("结束"), selection: $end)
          Toggle(L("设置本机通知"), isOn: $remind)
          if remind { DatePicker(L("提醒时刻"), selection: $reminder) }
        }
        if timed && end <= start {
          Text(L("结束时间必须晚于开始时间")).foregroundStyle(accent)
        }
        if timed && remind && (reminder <= Date() || reminder > start) {
          Text(L("提醒必须在未来且不晚于活动开始")).foregroundStyle(accent)
        }
        if !cost.isEmpty && (Double(cost) == nil || Double(cost)! < 0 || !Double(cost)!.isFinite) {
          Text(L("费用需为有限的非负数")).foregroundStyle(accent)
        }
        VStack(alignment: .leading, spacing: 7) {
          Text(L("预计总费用", "Estimated total cost"))
          TextField(L("预计总费用（人民币；未知留空）"), text: $cost).textFieldStyle(WarmFieldStyle())
        }
        VStack(alignment: .leading, spacing: 7) {
          Text(L("备注与尚未确认事项", "Notes and open questions"))
          TextField(L("备注与尚未确认事项"), text: $notes, axis: .vertical).textFieldStyle(WarmFieldStyle())
        }
        if let plan = editablePlan {
          ForEach(Array(plan.stops.enumerated()), id: \.element.id) { index, stop in
            HStack {
              Text(stop.place.name)
              Spacer()
              Button(L("上移")) { moveStop(index, -1) }.disabled(index == 0)
              Button(L("下移")) { moveStop(index, 1) }.disabled(index == plan.stops.count - 1)
            }
          }
          Text(L("完整地点列表与来源会一并保存。费用和营业状态仍需核实。")).font(TypeScale.body).foregroundStyle(
            ink.opacity(0.68))
        }
        if !formError.isEmpty { Text(formError).foregroundStyle(accent) }
        HStack {
          Button(L("取消")) { dismiss() }
          Spacer()
          Button(busy ? L("正在保存…") : timed ? L("确认保存行程") : L("保存为草案")) { save() }.buttonStyle(
            WarmButtonStyle(primary: true)
          ).disabled(
            busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || (!cost.isEmpty
                && (Double(cost) == nil || Double(cost)! < 0 || !Double(cost)!.isFinite))
              || (timed && end <= start)
              || (timed && remind && (reminder <= Date() || reminder > start)))
        }
      }.font(TypeScale.body).buttonStyle(WarmButtonStyle()).disclosureGroupStyle(
        TextDisclosureStyle()
      ).toggleStyle(TextToggleStyle()).padding(32)
    }.frame(width: 650).frame(maxHeight: 680).background(paper).onAppear {
      participants = Set(
        outing?.payload.participant_ids ?? (participant.isEmpty ? [] : [participant]))
      if participants.isEmpty, let sourceProposal {
        let mentioned = model.state.people.filter { sourceProposal.item.text.contains($0.name) }
        if mentioned.count == 1 { participants = [mentioned[0].id] }
      }
      editablePlan = plan
      title =
        outing?.payload.title ?? plan?.stops.first?.place.name ?? sourceProposal?.item.text ?? ""
      location = outing?.payload.location_name ?? plan?.stops.first?.place.name ?? ""
      notes = outing?.payload.notes ?? plan?.notes ?? sourceProposal?.item.source_quote ?? ""
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
    action.source_entry_id = sourceProposal?.sourceID
    action.source_revision = sourceProposal?.sourceRevision
    action.evidence_quote = sourceProposal?.item.source_quote
    action.proposal_id = plan?.id
    action.proposal_revision = plan?.revision
    let resolvingProposal = sourceProposal.flatMap { proposal -> Proposal? in
      let personResolved =
        proposal.personID.map { participants.contains($0) } ?? (proposal.item.subject == "我")
      let issueResolved =
        proposal.issue == nil
        || (proposal.issue == "你想安排在哪一天？" && timed)
      return personResolved && issueResolved ? proposal : nil
    }
    Task {
      do {
        let id = try await store.execute(action, resolving: resolvingProposal, plan: plan)
        await model.refresh()
        if let saved = model.state.outings.first(where: { $0.id == id }) {
          let status = await Notifications.sync(saved)
          do {
            try await store.notification(id, revision: saved.revision, status: status)
            await model.refresh()
          } catch {
            model.error =
              L("行程已保存，但提醒状态未能写入：", "Outing saved, but reminder status could not be stored: ")
              + L(error.localizedDescription)
          }
        }
        if sourceProposal != nil && resolvingProposal == nil {
          model.notice = L(
            "行程草案已保存；原文计划仍待明确人物或时间。",
            "Outing draft saved; the source plan still needs a person or date."
          )
        }
        dismiss()
      } catch {
        formError = L(error.localizedDescription)
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
    PageTitle(title: L("按照你的方式使用"), subtitle: L("记忆属于你。模型可以更换，已经确认的资料会一直留在这里。"))
    Card {
      Picker("Language / 语言", selection: $model.language) {
        Text("中文").tag("zh")
        Text("English").tag("en")
      }.pickerStyle(.segmented).frame(maxWidth: 360)
    }
    Card {
      VStack(alignment: .leading, spacing: 18) {
        Text(L("模型与云端整理")).font(TypeScale.body)
        Picker(L("提供方"), selection: $model.config.provider) {
          ForEach(Provider.allCases) { Text($0.rawValue).tag($0) }
        }.onChange(of: model.config.provider) { _, provider in
          model.config.model = provider.suggestedModel
          model.config.nativeSchema = false
          model.config.toolsDeclared = false
          model.configStatus = L("能力尚未验证")
          key = ""
        }
        VStack(alignment: .leading, spacing: 7) {
          Text(L("模型 ID", "Model ID"))
          TextField(L("模型 ID（可按账户可用模型修改）"), text: $model.config.model).textFieldStyle(
            WarmFieldStyle())
        }
        VStack(alignment: .leading, spacing: 7) {
          Text(L("API Key"))
          SecureField(L("API Key（留空保留已存密钥）"), text: $key).textFieldStyle(WarmFieldStyle())
        }
        Toggle(L("允许将本条原文和必要上下文发送给所选模型"), isOn: $model.config.cloudConsent)
        Toggle(L("当前模型支持工具调用（配置声明，非验证结果）"), isOn: $model.config.toolsDeclared)
        Toggle(L("使用原生 Schema（仅支持对应接口的模型）"), isOn: $model.config.nativeSchema)
        Text(L("默认使用 JSON 输出与本地完整校验。模型可用性取决于你的账户；不会自动切换提供方。")).font(TypeScale.body).foregroundStyle(
          ink.opacity(0.68))
        HStack {
          Button(L("保存配置与密钥")) {
            model.saveConfig(key: key, jevKey: jevKey, braveKey: braveKey)
            key = ""
            jevKey = ""
            braveKey = ""
          }
          Button(L("测试文本连接")) { model.testConnection() }
        }
        Text(L(model.configStatus)).font(TypeScale.body).foregroundStyle(ink.opacity(0.68))
      }
    }
    Card {
      VStack(alignment: .leading, spacing: 16) {
        Text(L("可选能力")).font(TypeScale.body)
        Toggle(L("启用 Jev 语义判断辅助"), isOn: $model.config.jevEnabled)
        Text(L("启用后会发送必要原文、候选与少量相关记忆。判断不会自动确认记忆，失败时保留人工处理。")).font(TypeScale.body).foregroundStyle(
          ink.opacity(0.68))
        VStack(alignment: .leading, spacing: 7) {
          Text(L("Jev 模型", "Jev model"))
          TextField(L("Jev 模型"), text: $model.config.jevModel).textFieldStyle(WarmFieldStyle())
        }
        VStack(alignment: .leading, spacing: 7) {
          Text(L("Jev 独立 Key", "Jev API key"))
          SecureField(L("Jev 独立 Key"), text: $jevKey).textFieldStyle(WarmFieldStyle())
        }
        VStack(alignment: .leading, spacing: 7) {
          Text(L("Brave Search Key（可选）", "Brave Search key (optional)"))
          SecureField(L("Brave Search Key（可选）"), text: $braveKey).textFieldStyle(WarmFieldStyle())
        }
        Text(L("未配置网页搜索时仍可查询地图与天气。输入后点击上方“保存配置与密钥”。")).font(TypeScale.body).foregroundStyle(
          ink.opacity(0.68))
      }
    }
    Card {
      VStack(alignment: .leading, spacing: 16) {
        Text(L("数据与演示")).font(TypeScale.body)
        HStack {
          Button(L("导出备份")) { model.exportBackup() }
          Button(L("从备份恢复…")) { model.restoreBackup() }
          Button(L("在 Finder 中查看数据")) { NSWorkspace.shared.open(model.directory) }
        }
        Button(L("归档当前资料库并开始新库…", "Archive library and start new…")) {
          model.archiveAndStartNew()
        }
        Text(L("恢复前先预览内容并备份当前状态。备份不包含 API Key。")).font(TypeScale.body).foregroundStyle(
          ink.opacity(0.68))
        Divider()
        Toggle(
          L("下一条固定演示样例使用合成响应", "Use synthetic response for the next demo sample"),
          isOn: $model.demo)
        Button(L("准备虚构人物与演示输入")) { model.loadDemo() }
        Text(L("只添加虚构人物并填入输入框；点击保存后才创建记录。演示不冒充实际模型或联网结果。")).font(TypeScale.body).foregroundStyle(
          ink.opacity(0.68))
      }
    }
  }
}
