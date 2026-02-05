import Foundation

/// A barrier represents a single undoable user action, grouping all database
/// changes that occurred between `beginBarrier` and `endBarrier`.
///
/// When undo is performed, all changes within the barrier are reversed in
/// reverse chronological order.
///
/// ## Sequence Numbers
///
/// The `startSeq` and `endSeq` store the ORIGINAL sequence range when the
/// barrier was created. However, after undo/redo operations, the actual
/// entries in the undolog move to new sequence positions (seq numbers grow,
/// they are not reused). `UndoEngine` tracks the current seq range separately
/// in `barrierSeqRanges` - see that documentation for details.
public struct UndoBarrier: Hashable, Sendable, Codable {
  /// Unique identifier for this barrier.
  public let id: UUID
  /// Display name for the action (shown in Edit > Undo menu).
  public let name: String
  /// Original first sequence number when barrier was created (may not reflect current position).
  let startSeq: Int
  /// Original last sequence number when barrier was created (may not reflect current position).
  let endSeq: Int

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
