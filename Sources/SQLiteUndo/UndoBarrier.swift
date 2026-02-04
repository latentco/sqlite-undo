import Foundation

/// A barrier represents a single undoable user action, grouping all database
/// changes that occurred between `beginBarrier` and `endBarrier`.
///
/// When undo is performed, all changes within the barrier are reversed in
/// reverse chronological order. The barrier stores the range of sequence
/// numbers from the undolog table that should be reversed together.
public struct UndoBarrier: Hashable, Sendable, Codable {
  /// Unique identifier for this barrier.
  public let id: UUID
  /// Display name for the action (shown in Edit > Undo menu).
  public let name: String
  /// First sequence number in the undolog for this barrier (inclusive).
  public let startSeq: Int
  /// Last sequence number in the undolog for this barrier (inclusive).
  public let endSeq: Int

  public init(id: UUID, name: String, startSeq: Int, endSeq: Int) {
    self.id = id
    self.name = name
    self.startSeq = startSeq
    self.endSeq = endSeq
  }

  /// The number of undolog entries in this barrier.
  public var count: Int {
    endSeq - startSeq + 1
  }
}
