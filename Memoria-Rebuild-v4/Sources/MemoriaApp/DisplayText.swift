import Foundation
import MemoriaCore

extension Evidence {
  var displayName: String {
    switch self {
    case .direct: return L("原文陈述")
    case .reported: return L("转述内容")
    case .uncertain: return L("尚不确定的判断")
    case .hypothetical: return L("条件或假设")
    }
  }
}
extension MemoryStatus {
  var displayName: String {
    switch self {
    case .active: return L("当前有效")
    case .superseded: return L("已被更新")
    case .revoked: return L("已撤销")
    case .deleted: return L("已删除")
    }
  }
}
extension ToolReceipt {
  var displayName: String {
    switch name {
    case "search_places": return L("地点查询")
    case "get_weather": return L("天气预报")
    case "search_web": return L("网页信息")
    case "search_memories": return L("相关记忆")
    case "propose_outing": return L("活动草案")
    default: return L("查询")
    }
  }
  var weatherDescription: String {
    func first(_ key: String) -> String {
      guard let number = (data[key] as? [NSNumber])?.first else { return L("未知") }
      return number.stringValue
    }
    return
      L("气温", "Temperature")
      + " \(first("temperature_2m_min")) – \(first("temperature_2m_max")) °C · "
      + L("降雨概率", "Rain chance") + " \(first("precipitation_probability_max"))%"
  }
}
