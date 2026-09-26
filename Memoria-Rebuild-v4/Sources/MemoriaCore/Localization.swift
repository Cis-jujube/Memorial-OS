import Foundation

public enum InterfaceCopy {
  public static let english: [String: String] = {
    guard let url = Bundle.module.url(forResource: "en", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let result = try? JSONDecoder().decode([String: String].self, from: data)
    else { return [:] }
    return result
  }()
  public static func text(_ key: String, language: String) -> String {
    guard language == "en" else { return key }
    if let translated = english[key] { return translated }
    let httpPrefix = "服务请求失败（HTTP "
    if key.hasPrefix(httpPrefix), key.hasSuffix("）。"),
      let code = Int(key.dropFirst(httpPrefix.count).dropLast(2))
    {
      return "Service request failed (HTTP \(code))."
    }
    // Schema diagnostics are app-generated paths followed by a fixed validation reason.
    if key.hasPrefix("$"), let separator = key.range(of: "："),
      let reason = english[String(key[separator.upperBound...])]
    {
      return String(key[..<separator.lowerBound]) + ": " + reason
    }
    return key
  }
}
