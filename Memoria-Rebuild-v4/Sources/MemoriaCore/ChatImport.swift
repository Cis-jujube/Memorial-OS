import CryptoKit
import Foundation

/// Conservative text intake. Blank-line-separated excerpts retain sender/date text verbatim.
/// This does not decode WeChat databases or infer the identity of message participants.
public struct ImportExcerpt: Identifiable, Equatable {
  public var id: String
  public var text: String
  public init(text: String) {
    self.text = text
    id = Self.fingerprint(text)
  }
  public static func fingerprint(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  public func operationID(personID: String?) -> String {
    "import:" + Self.fingerprint((personID ?? "") + "\u{0}" + text)
  }
}
public enum ChatImport {
  public static func parse(_ input: String, splitParagraphs: Bool = true) throws -> [ImportExcerpt]
  {
    guard input.utf8.count <= 2_000_000 else {
      throw MemoriaError.invalid("导入文本不能超过 2 MB")
    }
    let normalized = input.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    let parts =
      splitParagraphs
      ? normalized.components(separatedBy: try NSRegularExpression(pattern: "\\n[\\t ]*\\n+"))
      : [normalized]
    var seen = Set<String>()
    let excerpts = parts.compactMap { part -> ImportExcerpt? in
      let value = part.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty else { return nil }
      let excerpt = ImportExcerpt(text: value)
      return seen.insert(excerpt.id).inserted ? excerpt : nil
    }
    guard !excerpts.isEmpty, excerpts.count <= 500,
      excerpts.allSatisfy({ $0.text.count <= 100_000 })
    else { throw MemoriaError.invalid("请导入 1 至 500 段文本，每段最多 100000 字") }
    return excerpts
  }
}
extension String {
  fileprivate func components(separatedBy regex: NSRegularExpression) -> [String] {
    let ns = self as NSString
    var offset = 0
    var parts: [String] = []
    for match in regex.matches(in: self, range: NSRange(location: 0, length: ns.length)) {
      parts.append(
        ns.substring(with: NSRange(location: offset, length: match.range.location - offset)))
      offset = NSMaxRange(match.range)
    }
    parts.append(ns.substring(from: offset))
    return parts
  }
}
public struct ImportReceipt {
  public var added: Int
  public var skipped: Int
}
