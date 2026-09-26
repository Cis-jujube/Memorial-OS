import AppKit
import MemoriaCore
import SwiftUI

// Select the property wrapper explicitly on SDKs that also expose a State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

@main struct MemoriaApp: App {
  @StateObject private var model = AppModel()
  var body: some Scene {
    Window("Memoria", id: "main") {
      RootView().environmentObject(model).environment(\.locale, Locale(identifier: model.language))
        .frame(minWidth: 900, minHeight: 660)
        .preferredColorScheme(.light)
        .onAppear {
          NSApp.setActivationPolicy(.regular)
          NSApp.activate(ignoringOtherApps: true)
        }
    }.defaultSize(width: 1260, height: 900)
      .commands {
        CommandGroup(after: .newItem) {
          Button(L("问一问")) { model.page = "问一问" }.keyboardShortcut("k", modifiers: .command)
          Button(L("整理台")) { model.page = "整理台" }.keyboardShortcut(
            "r", modifiers: [.command, .shift])
          Button(L("写一条记录")) { model.page = "记录" }.keyboardShortcut("n", modifiers: .command)
        }
      }
  }
}

// Exactly two text sizes across every product page and sheet.
enum TypeScale {
  static let title = Font.system(size: 28, weight: .semibold)
  static let body = Font.system(size: 16)
}
let ink = Color(red: 0.24, green: 0.13, blue: 0.12)
let accent = Color(red: 0.69, green: 0.20, blue: 0.13)
let ember = Color(red: 0.76, green: 0.29, blue: 0.13)
let paper = Color(red: 0.99, green: 0.97, blue: 0.94)
let warmGradient = LinearGradient(
  colors: [accent, ember], startPoint: .topLeading, endPoint: .bottomTrailing)

struct WarmButtonStyle: ButtonStyle {
  var primary = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var enabled
  @ViewState private var hovering = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(TypeScale.body.weight(primary ? .semibold : .regular))
      .padding(.horizontal, primary ? 20 : 12).padding(.vertical, 11)
      .foregroundStyle(primary ? .white : accent)
      .background {
        if primary {
          RoundedRectangle(cornerRadius: 13).fill(warmGradient)
        } else {
          RoundedRectangle(cornerRadius: 11).fill(accent.opacity(hovering ? 0.09 : 0.035))
        }
      }
      .opacity(enabled ? 1 : 0.38)
      .scaleEffect(
        reduceMotion ? 1 : configuration.isPressed ? 0.955 : hovering && primary ? 1.018 : 1
      )
      .offset(y: reduceMotion ? 0 : configuration.isPressed ? 1 : 0)
      .animation(
        reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.58),
        value: configuration.isPressed
      )
      .animation(
        reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.68), value: hovering
      )
      .onHover { hovering = $0 }
  }
}
struct TextToggleStyle: ToggleStyle {
  @Environment(\.locale) private var locale
  var selection = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func makeBody(configuration: Configuration) -> some View {
    Button {
      withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.68)) {
        configuration.isOn.toggle()
      }
    } label: {
      HStack(spacing: 12) {
        configuration.label
        Text(
          selection
            ? (configuration.isOn ? L("已选", "Selected") : L("未选", "Not selected"))
            : (configuration.isOn ? L("已开启") : L("未开启"))
        )
        .foregroundStyle(configuration.isOn ? Color.white : accent)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(configuration.isOn ? accent : accent.opacity(0.07), in: Capsule())
      }.font(TypeScale.body).contentShape(Rectangle())
    }.buttonStyle(.plain)
      .accessibilityValue(configuration.isOn ? L("开启") : L("关闭")).id(locale.identifier)
  }
}

struct WarmFieldStyle: TextFieldStyle {
  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration.textFieldStyle(.plain).font(TypeScale.body)
      .padding(.horizontal, 16).padding(.vertical, 16)
      .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 13))
      .overlay(RoundedRectangle(cornerRadius: 13).stroke(accent.opacity(0.18), lineWidth: 1))
  }
}
struct TextDisclosureStyle: DisclosureGroupStyle {
  @Environment(\.locale) private var locale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 13) {
      Button {
        withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.75)) {
          configuration.isExpanded.toggle()
        }
      } label: {
        HStack {
          configuration.label
          Spacer()
          Text(configuration.isExpanded ? L("收起") : L("展开")).foregroundStyle(accent)
        }
      }.buttonStyle(.plain).font(TypeScale.body)
      if configuration.isExpanded {
        configuration.content.transition(.opacity.combined(with: .move(edge: .top)))
      }
    }.id(locale.identifier)
  }
}
struct Card<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    content.padding(26).frame(maxWidth: .infinity, alignment: .leading)
      .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 22))
      .overlay(RoundedRectangle(cornerRadius: 22).stroke(accent.opacity(0.07)))
  }
}
struct PageTitle: View {
  var title: String
  var subtitle: String
  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      Text(L(title)).font(TypeScale.title).foregroundStyle(ink).fixedSize(
        horizontal: false, vertical: true)
      Text(L(subtitle)).font(TypeScale.body).foregroundStyle(ink.opacity(0.68)).lineSpacing(5)
        .frame(
          maxWidth: 590, alignment: .leading)
    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12).padding(.bottom, 16)
  }
}
struct EmptyMessage: View {
  var title: String
  var detail: String
  var body: some View {
    HStack(alignment: .top, spacing: 28) {
      Rectangle().fill(warmGradient).frame(width: 3, height: 64)
      VStack(alignment: .leading, spacing: 13) {
        Text(L(title)).font(TypeScale.body.weight(.semibold))
        Text(L(detail)).foregroundStyle(ink.opacity(0.68)).lineSpacing(7).frame(
          maxWidth: 460, alignment: .leading)
      }
      Spacer(minLength: 50)
    }.font(TypeScale.body).padding(.vertical, 34).padding(.leading, 10)
  }
}
struct RootView: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var navigation
  let pages = ["记录", "整理台", "问一问", "人物", "行程", "导入", "设置"]
  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Memoria").font(.system(size: 28, weight: .semibold, design: .serif))
            .foregroundStyle(accent)
          Text(L("记得，也懂得。")).foregroundStyle(ink.opacity(0.68))
        }.padding(.top, 40).padding(.horizontal, 27)
        ScrollView {
          VStack(spacing: 9) {
            ForEach(pages, id: \.self) { name in
              Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.72)) {
                  model.page = name
                }
              } label: {
                HStack {
                  Text(L(name)).font(TypeScale.body.weight(model.page == name ? .semibold : .regular))
                  Spacer()
                  if name == "整理台" {
                    let count = model.state.proposals.filter { $0.status == .pending }.count
                    if count > 0 { Text("\(count)").contentTransition(.numericText()) }
                  }
                }.padding(.horizontal, 20).padding(.vertical, 17)
                  .foregroundStyle(model.page == name ? Color.white : ink.opacity(0.74))
                  .background {
                    if model.page == name {
                      RoundedRectangle(cornerRadius: 16).fill(warmGradient).matchedGeometryEffect(
                        id: "selection", in: navigation)
                    }
                  }.contentShape(Rectangle())
              }.buttonStyle(.plain).accessibilityAddTraits(model.page == name ? .isSelected : [])
            }
          }.padding(.leading, 16).padding(.trailing, 24)
        }.frame(maxHeight: .infinity)
        Picker("Language / 语言", selection: $model.language) {
          Text("中文").tag("zh")
          Text("English").tag("en")
        }.pickerStyle(.segmented).padding(.horizontal, 22)
        VStack(alignment: .leading, spacing: 14) {
          Text(
            model.demo && model.draft == AppModel.demoText
              ? L("演示样例已准备好", "Demo sample ready") : L("只属于你的记忆")
          ).foregroundStyle(accent)
          Text(L("先记录，后确认。\n让重要的事留下来。")).foregroundStyle(ink.opacity(0.68)).lineSpacing(7)
        }.padding(.horizontal, 27).padding(.bottom, 36)
      }.frame(width: 235)
        .background(
          LinearGradient(
            colors: [
              Color(red: 0.98, green: 0.89, blue: 0.83), Color(red: 1, green: 0.95, blue: 0.89),
            ], startPoint: .topLeading, endPoint: .bottomTrailing))
      VStack(spacing: 0) {
        HStack(alignment: .center) {
          if !model.notice.isEmpty {
            Text(L(model.notice)).foregroundStyle(accent).lineLimit(2).transition(
              .opacity.combined(with: .move(edge: .top)))
            Spacer()
            Button(L("知道了")) { model.notice = "" }
          } else {
            Text(
              Date().formatted(
                .dateTime.month(.wide).day().locale(Locale(identifier: model.language)))
            ).foregroundStyle(ink.opacity(0.68))
            Spacer()
            Text(L("留一点空间，给生活。")).foregroundStyle(ink.opacity(0.68))
          }
        }.font(TypeScale.body).padding(.horizontal, 38).frame(minHeight: 65)
          .animation(
            reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.72), value: model.notice)
        Rectangle().fill(warmGradient.opacity(0.18)).frame(height: 1)
        ScrollView {
          VStack(alignment: .leading, spacing: 26) {
            switch model.page {
            case "整理台": ReviewDeskView()
            case "导入": ImportView(session: model.importSession)
            case "问一问": RecallView()
            case "人物": PeopleView()
            case "行程": OutingsView()
            case "设置": SettingsView()
            default: CaptureView()
            }
          }.padding(.leading, 38).padding(.trailing, 52).padding(.top, 24).padding(.bottom, 50)
            .frame(maxWidth: 1130, alignment: .leading).frame(
              maxWidth: .infinity, alignment: .leading)
        }
      }.background(paper)
    }.font(TypeScale.body).foregroundStyle(ink).tint(accent)
      .buttonStyle(WarmButtonStyle()).disclosureGroupStyle(TextDisclosureStyle()).toggleStyle(
        TextToggleStyle()
      ).menuIndicator(.hidden)
      .alert(
        L("这一步没有完成"),
        isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
      ) {
        Button(L("知道了"), role: .cancel) { model.error = nil }
      } message: {
        Text(L(model.error ?? ""))
      }
      .sheet(item: $model.outingProposal) { proposal in
        OutingSheet(
          outing: nil, plan: nil, participant: proposal.personID ?? "", sourceProposal: proposal)
      }
      .sheet(item: $model.sourcePreview) { source in
        VStack(alignment: .leading, spacing: 22) {
          HStack {
            Text(L("原文依据")).font(TypeScale.title)
            Spacer()
            Button(L("关闭")) { model.sourcePreview = nil }
          }
          Text(displayDate(source.created)).foregroundStyle(
            ink.opacity(0.68))
          ScrollView {
            Text(source.text).textSelection(.enabled).lineSpacing(8).frame(
              maxWidth: .infinity, alignment: .leading)
          }
          if source.demo { Text(L("这是一条演示数据")).foregroundStyle(accent) }
        }.font(TypeScale.body).buttonStyle(WarmButtonStyle()).padding(34).frame(
          width: 670, height: 460
        ).background(paper)
      }
  }
}
struct PersonPicker: View {
  @EnvironmentObject var model: AppModel
  @Binding var selection: String
  var label = L("关联人物")
  var queryScope = false
  var requireExplicit = false
  var body: some View {
    Picker(L(label), selection: $selection) {
      if queryScope {
        Text(L("自动识别人物", "Detect person from question")).tag("")
        Text(L("自己", "Myself")).tag("__self")
      } else {
        if requireExplicit {
          Text(L("请选择归属", "Choose whose memory this is")).tag("__choose")
        }
        Text(requireExplicit ? L("自己", "Myself") : L("自己 / 未关联")).tag("")
      }
      ForEach(model.state.people) { person in
        Text(person.name + (person.note.isEmpty ? "" : " · " + person.note)).tag(person.id)
      }
    }.font(TypeScale.body).controlSize(.large).frame(maxWidth: 360)
  }
}
