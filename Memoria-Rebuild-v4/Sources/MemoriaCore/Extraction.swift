import Foundation

public struct ChunkReport: Codable {
  public var index: Int
  public var text: String
  public var analysis: EntryAnalysis?
  public var error: String?
}
public struct ExtractionBatch {
  public var chunks: [ChunkReport]
  public var analyses: [EntryAnalysis] { chunks.compactMap(\.analysis) }
  public var remaining: [String] {
    chunks.filter { $0.analysis == nil }.map(\.text) + analyses.flatMap(\.unprocessed_quotes)
  }
}
public enum SourceChunker {
  // Character boundaries preserve composed Chinese/emoji text and exact quotations.
  public static func split(_ text: String, limit: Int = 1600) -> [String] {
    guard !text.isEmpty else { return [] }
    var chunks: [String] = []
    var start = text.startIndex
    while start < text.endIndex {
      var end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
      if end < text.endIndex {
        let segment = text[start..<end]
        if let boundary = segment.lastIndex(where: { "。！？\n".contains($0) }), boundary > start {
          end = text.index(after: boundary)
        }
      }
      chunks.append(String(text[start..<end]))
      start = end
    }
    return chunks
  }
}
extension ModelClient {
  public func extractBatch(_ source: Entry, people: [Person], cached: [ChunkReport] = [])
    async throws -> ExtractionBatch
  {
    let chunks = SourceChunker.split(source.text)
    let clock = ContinuousClock()
    let began = clock.now
    var reports: [ChunkReport] = []
    for (index, text) in chunks.enumerated() {
      try Task.checkCancellation()
      if let existing = cached.first(where: {
        $0.index == index && $0.text == text && $0.analysis != nil
      }) {
        reports.append(existing)
        continue
      }
      let elapsed = Double(began.duration(to: clock.now).components.seconds)
      let remaining = 90 - elapsed
      guard remaining > 1 else {
        reports.append(ChunkReport(index: index, text: text, error: "本次整理达到 90 秒预算，可稍后重试这一段"))
        continue
      }
      var piece = source
      piece.text = text
      do {
        let input = piece
        let analysis = try await withDeadline(seconds: remaining) {
          try await self.extract(input, people: people)
        }
        reports.append(ChunkReport(index: index, text: text, analysis: analysis))
      } catch {
        try Task.checkCancellation()
        reports.append(ChunkReport(index: index, text: text, error: error.localizedDescription))
        // Configuration failures should not fan out into repeated paid requests.
        if let failure = error as? MemoriaError {
          switch failure {
          case .missingKey, .configuration, .http(401), .http(403), .http(429):
            reports += chunks.enumerated().filter { $0.offset > index }.map {
              ChunkReport(index: $0.offset, text: $0.element, error: "请先解决服务配置或限流问题")
            }
            return ExtractionBatch(chunks: reports)
          default: break
          }
        }
      }
    }
    return ExtractionBatch(chunks: reports)
  }
}
