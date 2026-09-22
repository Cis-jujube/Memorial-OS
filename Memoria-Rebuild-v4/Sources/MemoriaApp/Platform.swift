import AppKit
import Darwin
import MemoriaCore
import Security
import UserNotifications

final class SingleInstance {
  private var descriptor: Int32 = -1
  func acquire(directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    descriptor = open(
      directory.appendingPathComponent("writer.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      throw MemoriaError.invalid("Memoria 已在运行，请使用已打开的窗口。")
    }
  }
  deinit { if descriptor >= 0 { close(descriptor) } }
}
enum Credentials {
  static let service = "local.jujube.memoria.rebuild.v4"
  static func read(_ account: String) throws -> String {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account, kSecReturnData as String: true,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return "" }
    guard status == errSecSuccess, let data = result as? Data,
      let string = String(data: data, encoding: .utf8)
    else { throw MemoriaError.invalid("无法从钥匙串读取密钥（\(status)）") }
    return string
  }
  static func save(_ account: String, value: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var insert = query
      insert[kSecValueData as String] = Data(value.utf8)
      insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let result = SecItemAdd(insert as CFDictionary, nil)
      guard result == errSecSuccess else { throw MemoriaError.invalid("密钥保存失败（\(result)）") }
    } else if status != errSecSuccess {
      throw MemoriaError.invalid("密钥保存失败（\(status)）")
    }
  }
}
enum Notifications {
  static func sync(_ outing: Outing) async -> String {
    let center = UNUserNotificationCenter.current()
    center.removePendingNotificationRequests(withIdentifiers: [outing.id])
    guard !outing.cancelled, let date = outing.payload.remind_at.flatMap(parseDate) else {
      return "未设置提醒"
    }
    guard date > Date() else { return "提醒时间已过，请重新选择" }
    do {
      guard try await center.requestAuthorization(options: [.alert, .sound]) else {
        return "行程已保存，通知未启用"
      }
      let content = UNMutableNotificationContent()
      content.title = outing.payload.title
      content.body = outing.payload.location_name ?? "打开 Memoria 查看行程"
      content.sound = .default
      let trigger = UNTimeIntervalNotificationTrigger(
        timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
      try await center.add(
        UNNotificationRequest(identifier: outing.id, content: content, trigger: trigger))
      return "提醒已安排"
    } catch { return "行程已保存，提醒安排失败：\(error.localizedDescription)" }
  }
}
