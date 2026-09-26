import AppKit
import MemoriaCore
import SwiftUI
import UniformTypeIdentifiers

struct ReviewDeskView: View {
  @EnvironmentObject var model: AppModel
  @ViewState private var person = "all"
  @ViewState private var search = ""
  var pending: [Proposal] { model.state.proposals.filter { $0.status == .pending } }
  var attentionEntries: [Entry] {
    model.state.entries.filter { ReviewQueue.needsAttention($0, in: model.state) }
  }
  var unorganizedEntries: [Entry] {
    model.state.entries.filter { ReviewQueue.isUnorganized($0, in: model.state) }
  }
  var body: some View {
    PageTitle(
      title: L("整理台", "Review desk"),
      subtitle: L(
        "原文已经留下。哪些值得记住，由你来决定。", "Your records are saved. You decide what becomes a memory."))
    HStack(spacing: 12) {
      ForEach(["pending", "attention", "unorganized"], id: \.self) { value in
        Button {
          model.reviewFilter = value
        } label: {
          Text(
            value == "pending"
              ? L("待确认", "To review") + " · \(pending.count)"
              : value == "attention"
                ? L("需要处理", "Needs attention") + " · \(attentionEntries.count)"
                : L("未整理原文", "Unorganized") + " · \(unorganizedEntries.count)")
        }.buttonStyle(WarmButtonStyle(primary: model.reviewFilter == value)).accessibilityAddTraits(
          model.reviewFilter == value ? .isSelected : [])
      }
    }
    HStack {
      TextField(L("搜索建议或原文", "Search suggestions or records"), text: $search).textFieldStyle(
        WarmFieldStyle())
      Picker(L("人物范围", "Person"), selection: $person) {
        Text(L("所有人物", "Everyone")).tag("all")
        Text(L("未关联人物", "No person assigned")).tag("")
        ForEach(model.state.people) { Text($0.name).tag($0.id) }
      }.frame(maxWidth: 280)
    }
    if model.reviewFilter == "pending" && !attentionEntries.isEmpty {
      Card {
        VStack(alignment: .leading, spacing: 12) {
          Text(L("还有原文正在整理或需要处理", "Some records are still organizing or need attention")).font(
            TypeScale.body.weight(.semibold))
          Text(
            L(
              "原文已保存。没有建议不代表整理完成；可查看进度、错误，或手动整理。",
              "Your records are saved. An empty queue does not mean organization is complete. Check progress, errors or organize manually."
            ))
          Button(L("查看整理状态", "View organization status")) { model.reviewFilter = "attention" }
        }
      }
    }
    if model.reviewFilter == "pending" {
      let items = pending.filter {
        (person == "all" || $0.personID == person.nilIfEmpty)
          && (search.isEmpty || $0.item.text.localizedCaseInsensitiveContains(search)
            || $0.item.source_quote.localizedCaseInsensitiveContains(search))
      }
      if items.isEmpty {
        EmptyMessage(
          title: !search.isEmpty || person != "all"
            ? L("没有匹配的建议", "No matching suggestions")
            : attentionEntries.isEmpty && unorganizedEntries.isEmpty
              ? L("这一页已整理好", "All clear here") : L("暂无可确认建议", "No suggestions ready yet"),
          detail: L(
            "没有匹配的待确认建议。可以继续记录，或查看未整理原文。",
            "No matching suggestions. Capture something new or review unorganized records."))
      }
      LazyVStack(spacing: 18) {
        ForEach(items) { proposal in
          Card { ProposalCard(proposal: proposal) }
        }
      }
    } else {
      let entries = model.state.entries.filter { entry in
        guard !entry.deleted, person == "all" || entry.personID == person.nilIfEmpty,
          search.isEmpty || entry.text.localizedCaseInsensitiveContains(search)
        else { return false }
        if model.reviewFilter == "attention" {
          return ReviewQueue.needsAttention(entry, in: model.state)
        }
        return ReviewQueue.isUnorganized(entry, in: model.state)
      }
      if entries.isEmpty {
        EmptyMessage(
          title: !search.isEmpty || person != "all"
            ? L("没有匹配的记录", "No matching records") : L("这里暂时没有记录", "Nothing here yet"),
          detail: L(
            "导入或保存的原文会出现在这里。失败的整理也能在此重试。",
            "Saved and imported records appear here. Interrupted organization can be retried."))
      }
      LazyVStack(spacing: 18) { ForEach(entries) { EntryCard(entry: $0) } }
    }
  }
}

final class ImportSession: ObservableObject {
  @Published var input = ""
  @Published var person = ""
  @Published var split = true
  @Published var excerpts: [ImportExcerpt] = []
  @Published var selected: Set<String> = []
  @Published var busy = false
  @Published var issue = ""
  @Published var receipt: ImportReceipt?
  @Published var previewInput = ""
  @Published var previewSplit = true
  @Published var previewPerson = ""
}

struct ImportView: View {
  @EnvironmentObject var model: AppModel
  @ObservedObject var session: ImportSession
  var previewCurrent: Bool {
    session.input == session.previewInput && session.split == session.previewSplit
      && session.person == session.previewPerson
  }
  var body: some View {
    PageTitle(
      title: L("让聊天里的小事，留下来", "Bring the little things with you"),
      subtitle: L(
        "粘贴微信聊天文字，或读取文本文件。先预览、再选择；只保存在本机，不自动整理。",
        "Paste WeChat chat text or open a text file. Preview and choose what to keep. Import stays local and does not run AI."
      ))
    Card {
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          Text(L("聊天文本", "Chat text"))
          Spacer()
          Button(L("选择文本文件", "Open text file")) { chooseFile() }.disabled(session.busy)
        }
        TextEditor(text: $session.input).font(TypeScale.body).frame(minHeight: 220)
          .scrollContentBackground(.hidden).padding(12).background(
            paper, in: RoundedRectangle(cornerRadius: 14)
          )
          .accessibilityLabel(L("待导入聊天文本", "Chat text to import"))
          .disabled(session.busy)
        Text(
          L(
            "支持 UTF-8 / UTF-16 的 TXT、Markdown 文本，最多 2 MB。保留原有姓名、时间和顺序；不会自动判断说话人。微信备份数据库不能直接导入。",
            "UTF-8 / UTF-16 TXT or Markdown, up to 2 MB. Names, timestamps and message order remain in the text; speakers are not inferred. WeChat backup databases are not supported."
          )
        )
        .foregroundStyle(ink.opacity(0.68))
        Toggle(
          L("按空行分段（关闭则保留完整原文）", "Split at blank lines (off keeps one record)"), isOn: $session.split
        )
        .disabled(session.busy)
        PersonPicker(
          selection: $session.person, label: L("关联人物（可留空）", "Associate a person (optional)")
        )
        .disabled(session.busy)
        Button(L("预览导入", "Preview import")) { preview() }.buttonStyle(
          WarmButtonStyle(primary: true)
        )
        .disabled(
          session.busy || session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if !session.issue.isEmpty {
          Text(L(session.issue)).foregroundStyle(accent).accessibilityAddTraits(.updatesFrequently)
        }
        if let receipt = session.receipt {
          Text(
            L("已导入", "Imported") + " \(receipt.added) · " + L("重复跳过", "Duplicates skipped")
              + " \(receipt.skipped)"
          ).foregroundStyle(accent)
          Button(L("到整理台继续", "Continue in Review desk")) {
            model.reviewFilter = "unorganized"
            model.page = "整理台"
          }
        }
      }
    }
    if !session.excerpts.isEmpty && !previewCurrent {
      Text(L("输入或人物已更改，请重新预览后再导入。", "Text or person changed. Preview again before importing."))
        .foregroundStyle(accent)
    }
    if !session.excerpts.isEmpty && previewCurrent {
      HStack {
        Text(
          L("选择要保存的片段", "Choose excerpts to save")
            + " · \(session.selected.count) / \(session.excerpts.count)")
        Spacer()
        Button(L("全选", "Select all")) {
          session.selected = Set(session.excerpts.filter { !duplicate($0) }.map(\.id))
        }
        Button(L("清空选择", "Clear selection")) { session.selected = [] }
      }.disabled(session.busy)
      Text(
        L(
          "相同人物下已导入的片段会跳过，已删除的导入记录也不会自动恢复。相同文字的片段在这次预览中合并显示。",
          "Previously imported excerpts for this person are skipped, including deleted imports. Identical excerpts within this preview appear once."
        )
      )
      .foregroundStyle(ink.opacity(0.68))
      LazyVStack(spacing: 14) {
        ForEach(session.excerpts) { excerpt in
          Card {
            VStack(alignment: .leading, spacing: 12) {
              Toggle(
                isOn: Binding(
                  get: { session.selected.contains(excerpt.id) },
                  set: {
                    if $0 {
                      session.selected.insert(excerpt.id)
                    } else {
                      session.selected.remove(excerpt.id)
                    }
                  })
              ) {
                Text(
                  duplicate(excerpt)
                    ? L("已导入 · 将跳过", "Already imported · skipped") : L("保存这段", "Keep this excerpt"))
              }.toggleStyle(TextToggleStyle(selection: true)).disabled(
                session.busy || duplicate(excerpt))
              Text(excerpt.text).lineLimit(5).textSelection(.enabled)
              DisclosureGroup(L("查看完整片段", "Read full excerpt")) {
                Text(excerpt.text).textSelection(.enabled)
              }
            }
          }
        }
      }
      Button(session.busy ? L("正在导入…", "Importing…") : L("确认导入所选片段", "Import selected excerpts")) {
        commit()
      }
      .buttonStyle(WarmButtonStyle(primary: true)).disabled(
        session.busy || session.selected.isEmpty)
    }
  }
  func duplicate(_ excerpt: ImportExcerpt) -> Bool {
    model.state.operations[excerpt.operationID(personID: session.person.nilIfEmpty)] != nil
  }
  func preview() {
    do {
      session.excerpts = try ChatImport.parse(session.input, splitParagraphs: session.split)
      session.previewInput = session.input
      session.previewSplit = session.split
      session.previewPerson = session.person
      session.selected = Set(session.excerpts.filter { !duplicate($0) }.map(\.id))
      session.issue = ""
      session.receipt = nil
    } catch {
      session.issue = error.localizedDescription
      session.excerpts = []
      session.selected = []
    }
  }
  func chooseFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size <= 2_000_000 else { throw MemoriaError.invalid("导入文本不能超过 2 MB") }
      let data = try Data(contentsOf: url)
      let utf16BOM = data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])
      guard let text = String(data: data, encoding: utf16BOM ? .utf16 : .utf8),
        !text.contains("\u{0}")
      else {
        throw MemoriaError.invalid("请选择 UTF-8 或 UTF-16 文本文件")
      }
      session.input = text
      preview()
    } catch { session.issue = error.localizedDescription }
  }
  func commit() {
    guard let store = model.store, previewCurrent else { return }
    let chosen = session.excerpts.filter { session.selected.contains($0.id) }
    let associatedPerson = session.person.nilIfEmpty
    session.busy = true
    Task {
      defer { session.busy = false }
      do {
        let result = try await store.importExcerpts(chosen, personID: associatedPerson)
        await model.refresh()
        session.receipt = result
        session.excerpts = []
        session.selected = []
        session.input = ""
        session.issue = ""
      } catch { session.issue = error.localizedDescription }
    }
  }
}
