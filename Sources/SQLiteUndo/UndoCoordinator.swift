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

  /// Begin recording changes for a new undoable action.
  ///
  /// Changes are claimed by this barrier only while `_undoBarrierID` is set to its
  /// ID — see ``withBarrier(_:_:)-(_,()throws->Void)``, which scopes that for you.
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
    var barrier: UndoBarrier?
    try withBarrierScope(
      name,
      begin: beginBarrier,
      end: { barrier = try endBarrier($0) },
      cancel: cancelBarrier,
      operation: operation
    )
    return barrier
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
    var barrier: UndoBarrier?
    try await withBarrierScope(
      name,
      begin: beginBarrier,
      end: { barrier = try endBarrier($0) },
      cancel: cancelBarrier,
      operation: operation
    )
    return barrier
  }

  /// Cancel a barrier without registering it for undo.
  ///
  /// Any changes made within the barrier remain in the database but won't
  /// be undoable as a group. Use this for aborted operations.
  ///
  /// The entries are deleted whether or not the barrier is still open. A barrier that
  /// threw on its way out of `endBarrier` has already been forgotten here, and its
  /// rows would otherwise be orphaned in the log with nothing left to replay them.
  ///
  /// - Parameter id: The barrier ID returned from `beginBarrier`
  func cancelBarrier(_ id: UUID) throws {
    let name = state.withValue { $0.openBarriers.removeValue(forKey: id) }

    try database.write { db in
      try db.deleteUndoLogEntries(barrierID: id)
    }

    logger.debug("Cancel barrier: \(name ?? id.uuidString)")
  }

  /// Discard a closed barrier's undolog entries.
  ///
  /// Used when a barrier could not be registered for undo: nothing holds it, so its
  /// entries can never be replayed and would otherwise sit in the log forever. The
  /// database changes themselves stand — only the ability to undo them is gone.
  func discardBarrier(_ id: UUID) throws {
    try database.write { db in
      try db.deleteUndoLogEntries(barrierID: id)
    }
    logger.warning("Discarded unregistered barrier \(id) — its changes are not undoable")
  }

  /// Perform undo for a barrier.
  ///
  /// Executes all reverse SQL in the barrier in reverse order.
  /// The executed SQL is captured by triggers, becoming the redo SQL, and is
  /// re-stamped with this barrier's ID so it stays owned across cycles.
  ///
  /// - Returns: The event describing what changed, or nil if nothing was replayed.
  ///   The caller delivers it, since only it knows which undo scope this belongs to.
  @discardableResult
  func performUndo(barrier: UndoBarrier) throws -> UndoEvent? {
    guard let affectedItems = try replay(barrier: barrier) else { return nil }
    return UndoEvent(kind: .undo, name: barrier.name, affectedItems: affectedItems)
  }

  /// Perform redo for a barrier.
  ///
  /// Re-applies the original changes that were undone. The executed SQL is
  /// captured by triggers, becoming the undo SQL again.
  ///
  /// - Returns: The event describing what changed, or nil if nothing was replayed.
  @discardableResult
  func performRedo(barrier: UndoBarrier) throws -> UndoEvent? {
    guard let affectedItems = try replay(barrier: barrier) else { return nil }
    return UndoEvent(kind: .redo, name: barrier.name, affectedItems: affectedItems)
  }

  /// Replay a barrier's entries. Undo and redo are the same operation — each
  /// captures the reverse of what it executes.
  private func replay(barrier: UndoBarrier) throws -> Set<AffectedItem>? {
    try database.write { db in
      try db.performUndoRedo(barrierID: barrier.id)
    }
  }
}
