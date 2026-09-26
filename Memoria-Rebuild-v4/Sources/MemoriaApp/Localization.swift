import Foundation
import MemoriaCore

let isReviewSession = ProcessInfo.processInfo.arguments.contains("--review-session")
let appPreferences =
  isReviewSession ? UserDefaults(suiteName: "local.jujube.memoria.review")! : UserDefaults.standard

/// Applied to interface copy only. Personal names, records and quotations are never translated.
func L(_ chinese: String, _ english: String? = nil) -> String {
  let language =
    appPreferences.string(forKey: "interfaceLanguage")
    ?? (Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en")
  return language == "en" ? english ?? InterfaceCopy.text(chinese, language: language) : chinese
}

func displayNotificationStatus(_ storedStatus: String) -> String {
  // Older libraries may contain translated statuses; normalize them only for display.
  let legacyStatuses = [
    "未安排通知": "通知需要更新",
    "Reminder scheduled": "提醒已安排",
    "No reminder": "未设置提醒",
    "Reminder time has passed. Choose another time.": "提醒时间已过，请重新选择",
    "Outing saved; notifications disabled": "行程已保存，通知未启用",
    "Reminder needs updating": "通知需要更新",
  ]
  let failurePrefixes = ["行程已保存，提醒安排失败：", "Outing saved; reminder failed: "]
  if let prefix = failurePrefixes.first(where: storedStatus.hasPrefix) {
    return L("行程已保存，提醒安排失败：", "Outing saved; reminder failed: ")
      + storedStatus.dropFirst(prefix.count)
  }
  return L(legacyStatuses[storedStatus] ?? storedStatus)
}

func displayDate(_ date: Date, includeTime: Bool = true) -> String {
  let language =
    appPreferences.string(forKey: "interfaceLanguage")
    ?? (Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en")
  return date.formatted(
    Date.FormatStyle(date: .abbreviated, time: includeTime ? .shortened : .omitted).locale(
      Locale(identifier: language)))
}
