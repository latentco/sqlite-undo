import Foundation

/// A barrier represents a single undoable user action, grouping all database
/// changes made while it was open.
///
/// When undo is performed, all changes within the barrier are reversed in
/// reverse chronological order.
///
/// ## Entry Ownership
///
/// Undolog rows are stamped with the barrier's `id` as they are captured, so a
/// barrier owns its entries no matter what else writes concurrently. Replaying
/// a barrier re-stamps the newly captured reverse entries with the same `id`,
/// so ownership survives any number of undo/redo cycles.
public struct UndoBarrier: Hashable, Sendable, Codable {
  /// Unique identifier for this barrier, and the key its undolog entries carry.
  public let id: UUID
  /// Display name for the action (shown in Edit > Undo menu).
  public let name: String
  /// The number of undolog entries captured when this barrier closed.
  public let count: Int

  public init(id: UUID, name: String, count: Int) {
    self.id = id
    self.name = name
    self.count = count
  }
}
