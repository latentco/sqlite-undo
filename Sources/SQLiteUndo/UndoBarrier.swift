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

/// Run an operation inside a barrier: open one, claim the writes it makes, close it.
///
/// This is the only place a barrier is paired with its `_undoBarrierID` scope. A
/// barrier claims writes solely while that task local carries its ID, so opening one
/// any other way captures nothing at all — keeping the pairing here means callers
/// can't get it wrong.
func withBarrierScope<T>(
  _ name: String,
  begin: (String) throws -> UUID,
  end: (UUID) throws -> Void,
  cancel: (UUID) throws -> Void,
  operation: () throws -> T
) throws -> T {
  let id = try begin(name)
  do {
    let result = try $_undoBarrierID.withValue(id.uuidString) { try operation() }
    try end(id)
    return result
  } catch {
    try cancel(id)
    throw error
  }
}

/// Run an async operation inside a barrier. See ``withBarrierScope(_:begin:end:cancel:operation:)``.
func withBarrierScope<T: Sendable>(
  _ name: String,
  begin: (String) throws -> UUID,
  end: (UUID) throws -> Void,
  cancel: (UUID) throws -> Void,
  operation: @Sendable () async throws -> T
) async throws -> T {
  let id = try begin(name)
  do {
    let result = try await $_undoBarrierID.withValue(id.uuidString) { try await operation() }
    try end(id)
    return result
  } catch {
    try cancel(id)
    throw error
  }
}
