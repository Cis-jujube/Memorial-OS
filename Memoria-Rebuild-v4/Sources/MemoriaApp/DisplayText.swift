import Foundation
import MemoriaCore

extension Evidence {
  var displayName: String {
    switch self {
    case .direct: return "原文陈述"
    case .reported: return "转述内容"
    case .uncertain: return "尚不确定的判断"
    case .hypothetical: return "条件或假设"
    }
  }
}
extension MemoryStatus {
  var displayName: String {
    switch self {
    case .active: return "当前有效"
    case .superseded: return "已被更新"
    case .revoked: return "已撤销"
    case .deleted: return "已删除"
    }
  }
}
extension ToolReceipt {
  var displayName: String {
    switch name {
    case "search_places": return "地点查询"
    case "get_weather": return "天气预报"
    case "search_web": return "网页信息"
    case "search_memories": return "相关记忆"
    case "propose_outing": return "活动草案"
    default: return "查询"
    }
  }
  var weatherDescription: String {
    func first(_ key: String) -> String {
      guard let number = (data[key] as? [NSNumber])?.first else { return "未知" }
      return number.stringValue
    }
    return
      "气温 \(first("temperature_2m_min")) 至 \(first("temperature_2m_max")) °C；降雨概率 \(first("precipitation_probability_max"))%。"
  }
}
