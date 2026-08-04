import Dependencies
import Foundation
import IssueReporting
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "SQLiteUndo", category: "UndoCoordinator")

/// Internal coordinator that manages SQLite-based undo/redo for a database.
///
/// Uses database triggers to automatically capture reverse SQL for all changes
/// to tracked tables. Changes are grouped into "barriers" that represent
/// single user actions (e.g., "Set Rating", "Apply Look").
final class UndoCoordinator: Sendable {
  private let database: any DatabaseWriter
  private let registeredTables: Set<String>
  private let untrackedTables: Set<String>
  private let state = LockIsolated(State())

  private struct State {
    var openBarriers: [UUID: String] = [:]
    var subscribers: [UUID: AsyncStream<UndoEvent>.Continuation] = [:]
  }

  init(
    database: (any DatabaseWriter)? = nil,
    registeredTables: Set<String> = [],
    untrackedTables: Set<String> = []
  ) {
    @Dependency(\.defaultDatabase) var defaultDatabase
    self.database = database ?? defaultDatabase
    self.registeredTables = registeredTables
    self.untrackedTables = untrackedTables
  }

  /// Create a new stream of undo/redo events.
  ///
  /// Each call creates an independent subscription that receives events emitted from
  /// this point on; earlier events are not replayed.
  func events() -> AsyncStream<UndoEvent> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<UndoEvent>.makeStream()
    state.withValue { $0.subscribers[id] = continuation }
    continuation.onTermination = { [state] _ in
      state.withValue { _ = $0.subscribers.removeValue(forKey: id) }
    }
    return stream
  }

  /// Broadcast an event to all active subscribers.
  private func emit(_ event: UndoEvent) {
    // Copy out before yielding so `onTermination` can't re-enter the lock.
    for continuation in state.withValue({ Array($0.subscribers.values) }) {
      continuation.yield(event)
    }
  }

  /// Begin recording changes for a new undoable action.
  ///
  /// Changes are claimed by this barrier only while `_undoBarrierID` is set to its
  /// ID — see ``withBarrier(_:_:)``, which scopes that for you.
  ///
  /// - Parameter name: The action name (shown in Edit > Undo menu)
  /// - Returns: A unique ID for this barrier
  func beginBarrier(_ name: String) throws -> UUID {
    let id = UUID()
    state.withValue { $0.openBarriers[id] = name }
    logger.debug("Begin barrier: \(name) (id: \(id))")
    return id
  }

  /// End a barrier and capture all changes it claimed.
  ///
  /// If no changes were made within the barrier, returns nil.
  ///
  /// - Parameter id: The barrier ID returned from `beginBarrier`
  /// - Returns: The completed barrier, or nil if no changes were captured
  func endBarrier(_ id: UUID) throws -> UndoBarrier? {
    guard let name = state.withValue({ $0.openBarriers.removeValue(forKey: id) }) else {
      logger.warning("Attempted to end unknown barrier: \(id)")
      return nil
    }

    return try database.write { db in
      // Reconcile duplicate entries from cascading BEFORE triggers
      try db.reconcileUndoLogEntries(barrierID: id)

      let count = try db.undoLogCount(barrierID: id)
      guard count > 0 else {
        let tables = registeredTables.sorted()
        logger.warning(
          """
          End barrier (empty): \(name) — no database changes were captured.

          Did you forget to register a table with the UndoEngine?

          Registered tables:
          \(tables.map { "  \($0)" }.joined(separator: "\n"))
          """
        )
        return nil
      }

      let barrier = UndoBarrier(id: id, name: name, count: count)

      // Check for unregistered tables
      if !registeredTables.isEmpty {
        let modifiedTables = try db.tablesModified(barrierID: id)
        let allowedTables = registeredTables.union(untrackedTables)
        let unknownTables = modifiedTables.subtracting(allowedTables)
        if !unknownTables.isEmpty {
          reportIssue(
            """
            Barrier '\(name)' modified tables not registered with UndoEngine: \
            \(unknownTables.sorted().joined(separator: ", ")). \
            These changes won't be undone. Register the tables with UndoEngine, \
            or add them to 'untracked:' if this is intentional.
            """
          )
        }
      }

      logger.debug("End barrier: \(barrier.name) (\(barrier.count) entries)")
      return barrier
    }
  }

  /// Run an operation inside a barrier, returning the completed barrier.
  ///
  /// The barrier is cancelled if the operation throws. Changes must be made
  /// within the operation to be captured.
  ///
  /// - Returns: The completed barrier, or nil if no changes were captured.
  @discardableResult
  func withBarrier(_ name: String, _ operation: () throws -> Void) throws -> UndoBarrier? {
    let id = try beginBarrier(name)
    do {
      try $_undoBarrierID.withValue(id.uuidString) { try operation() }
      return try endBarrier(id)
    } catch {
      try cancelBarrier(id)
      throw error
    }
  }

  /// Run an async operation inside a barrier, returning the completed barrier.
  ///
  /// The barrier is cancelled if the operation throws. Changes must be made
  /// within the operation to be captured.
  ///
  /// - Returns: The completed barrier, or nil if no changes were captured.
  @discardableResult
  func withBarrier(
    _ name: String,
    _ operation: @Sendable () async throws -> Void
  ) async throws -> UndoBarrier? {
    let id = try beginBarrier(name)
    do {
      try await $_undoBarrierID.withValue(id.uuidString) { try await operation() }
      return try endBarrier(id)
    } catch {
      try cancelBarrier(id)
      throw error
    }
  }

  /// Cancel a barrier without registering it for undo.
  ///
  /// Any changes made within the barrier remain in the database but won't
  /// be undoable as a group. Use this for aborted operations.
  ///
  /// - Parameter id: The barrier ID returned from `beginBarrier`
  func cancelBarrier(_ id: UUID) throws {
    guard let name = state.withValue({ $0.openBarriers.removeValue(forKey: id) }) else {
      logger.warning("Attempted to cancel unknown barrier: \(id)")
      return
    }

    try database.write { db in
      try db.deleteUndoLogEntries(barrierID: id)
    }

    logger.debug("Cancel barrier: \(name)")
  }

  /// Perform undo for a barrier.
  ///
  /// Executes all reverse SQL in the barrier in reverse order.
  /// The executed SQL is captured by triggers, becoming the redo SQL, and is
  /// re-stamped with this barrier's ID so it stays owned across cycles.
  func performUndo(barrier: UndoBarrier) throws {
    if let affectedItems = try replay(barrier: barrier) {
      emit(UndoEvent(kind: .undo, name: barrier.name, affectedItems: affectedItems))
    }
  }

  /// Perform redo for a barrier.
  ///
  /// Re-applies the original changes that were undone. The executed SQL is
  /// captured by triggers, becoming the undo SQL again.
  func performRedo(barrier: UndoBarrier) throws {
    if let affectedItems = try replay(barrier: barrier) {
      emit(UndoEvent(kind: .redo, name: barrier.name, affectedItems: affectedItems))
    }
  }

  /// Replay a barrier's entries. Undo and redo are the same operation — each
  /// captures the reverse of what it executes.
  private func replay(barrier: UndoBarrier) throws -> Set<AffectedItem>? {
    try database.write { db in
      try db.performUndoRedo(barrierID: barrier.id)
    }
  }
}
