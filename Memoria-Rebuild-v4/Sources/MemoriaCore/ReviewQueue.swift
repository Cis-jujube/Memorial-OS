import Foundation

public enum ReviewQueue {
  public static let reviewedDecision = "用户已完成整条原文的人工审阅"
  public static func currentTask(for entry: Entry, in state: LibraryState) -> TaskState? {
    state.tasks.last { $0.source_id == entry.id && $0.input_revision == entry.revision }
  }
  public static func needsAttention(_ entry: Entry, in state: LibraryState) -> Bool {
    guard !entry.deleted, let task = currentTask(for: entry, in: state),
      task.decisionStatus != reviewedDecision
    else { return false }
    let pending = state.proposals.contains {
      $0.sourceID == entry.id && $0.sourceRevision == entry.revision && $0.status == .pending
    }
    return task.phase.running
      || [.failed, .cancelled, .interrupted, .no_suggestions].contains(task.phase)
      || !task.unprocessed.isEmpty || (task.phase == .awaiting_review && !pending)
  }
  public static func isUnorganized(_ entry: Entry, in state: LibraryState) -> Bool {
    !entry.deleted && currentTask(for: entry, in: state) == nil
  }
}
