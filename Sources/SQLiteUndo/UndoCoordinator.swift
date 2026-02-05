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
    var openBarriers: [UUID: OpenBarrier] = [:]

    /// Tracks current seq range for each barrier.
    ///
    /// ## Why this is needed
    ///
    /// Following the sqlite.org/undoredo pattern, sequence numbers are NOT reused.
    /// When you undo a barrier:
    /// 1. Original entries (e.g., seq 1-2) are deleted
    /// 2. Reverse SQL executes, triggers capture NEW entries (e.g., seq 3-4)
    /// 3. The barrier's "current" range is now 3-4, not 1-2
    ///
    /// The sqlite.org pattern stores `[begin, end]` pairs on undo/redo stacks,
    /// pushing the NEW range after each operation. We can't do that because
    /// NSUndoManager owns the stack and the barrier is captured in closures
    /// with fixed `startSeq`/`endSeq` values.
    ///
    /// Instead, we track the current seq range per barrier here. When undo/redo
    /// is performed, we look up the current range (not the original), execute
    /// the SQL, and update the range to wherever the new entries landed.
    var barrierSeqRanges: [UUID: SeqRange] = [:]
  }

  private struct OpenBarrier {
    let name: String
    let startSeq: Int
  }

  struct SeqRange {
    var startSeq: Int
    var endSeq: Int
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
  /// All database changes after this call will be captured in the undolog
  /// until `endBarrier` or `cancelBarrier` is called.
  ///
  /// - Parameter name: The action name (shown in Edit > Undo menu)
  /// - Returns: A unique ID for this barrier
  func beginBarrier(_ name: String) throws -> UUID {
    let id = UUID()
    try database.read { db in
      let currentSeq = try db.undoLogMaxSeq() ?? 0
      let startSeq = currentSeq + 1
      state.withValue {
        $0.openBarriers[id] = OpenBarrier(name: name, startSeq: startSeq)
      }
    }
    logger.debug("Begin barrier: \(name) (id: \(id))")
    return id
  }

  /// End a barrier and capture all changes made since it began.
  ///
  /// If no changes were made within the barrier, returns nil.
  ///
  /// - Parameter id: The barrier ID returned from `beginBarrier`
  /// - Returns: The completed barrier, or nil if no changes were captured
  func endBarrier(_ id: UUID) throws -> UndoBarrier? {
    guard let openBarrier = state.withValue({ $0.openBarriers.removeValue(forKey: id) }) else {
      logger.warning("Attempted to end unknown barrier: \(id)")
      return nil
    }

    return try database.read { db in
      guard let endSeq = try db.undoLogMaxSeq(), endSeq >= openBarrier.startSeq else {
        logger.debug("End barrier (empty): \(openBarrier.name)")
        return nil
      }

      let barrier = UndoBarrier(
        id: id,
        name: openBarrier.name,
        startSeq: openBarrier.startSeq,
        endSeq: endSeq
      )

      // Check for unregistered tables
      if !registeredTables.isEmpty {
        let modifiedTables = try db.tablesModifiedInRange(
          from: openBarrier.startSeq,
          to: endSeq
        )
        let allowedTables = registeredTables.union(untrackedTables)
        let unknownTables = modifiedTables.subtracting(allowedTables)
        if !unknownTables.isEmpty {
          reportIssue(
            """
            Barrier '\(openBarrier.name)' modified tables not registered with UndoEngine: \
            \(unknownTables.sorted().joined(separator: ", ")). \
            These changes won't be undone. Register the tables with UndoEngine, \
            or add them to 'untracked:' if this is intentional.
            """
          )
        }
      }

      // Track the seq range for this barrier
      state.withValue {
        $0.barrierSeqRanges[id] = SeqRange(startSeq: barrier.startSeq, endSeq: barrier.endSeq)
      }

      logger.debug("End barrier: \(barrier.name) (\(barrier.count) entries)")
      return barrier
    }
  }

  /// Cancel a barrier without registering it for undo.
  ///
  /// Any changes made within the barrier remain in the database but won't
  /// be undoable as a group. Use this for aborted operations.
  ///
  /// - Parameter id: The barrier ID returned from `beginBarrier`
  func cancelBarrier(_ id: UUID) throws {
    guard let openBarrier = state.withValue({ $0.openBarriers.removeValue(forKey: id) }) else {
      logger.warning("Attempted to cancel unknown barrier: \(id)")
      return
    }

    try database.write { db in
      if let endSeq = try db.undoLogMaxSeq(), endSeq >= openBarrier.startSeq {
        try db.deleteUndoLogEntries(from: openBarrier.startSeq, to: endSeq)
      }
    }

    logger.debug("Cancel barrier: \(openBarrier.name)")
  }

  /// Perform undo for a barrier.
  ///
  /// Executes all reverse SQL in the barrier in reverse order.
  /// The executed SQL is captured by triggers, becoming the redo SQL.
  ///
  /// The seq range used is looked up from `barrierSeqRanges` (not the barrier's
  /// original values) because entries move to new seq positions after each
  /// undo/redo. After execution, the tracked range is updated to the new positions.
  func performUndo(barrier: UndoBarrier) throws {
    let seqRange =
      state.withValue { $0.barrierSeqRanges[barrier.id] }
      ?? SeqRange(startSeq: barrier.startSeq, endSeq: barrier.endSeq)

    let newRange = try database.write { db in
      try db.performUndoRedo(startSeq: seqRange.startSeq, endSeq: seqRange.endSeq)
    }

    if let newRange {
      state.withValue {
        $0.barrierSeqRanges[barrier.id] = newRange
      }
    }
  }

  /// Perform redo for a barrier.
  ///
  /// Re-applies the original changes that were undone.
  /// The executed SQL is captured by triggers, becoming the undo SQL again.
  ///
  /// The seq range used is looked up from `barrierSeqRanges` (not the barrier's
  /// original values) because entries move to new seq positions after each
  /// undo/redo. After execution, the tracked range is updated to the new positions.
  func performRedo(barrier: UndoBarrier) throws {
    let seqRange =
      state.withValue { $0.barrierSeqRanges[barrier.id] }
      ?? SeqRange(startSeq: barrier.startSeq, endSeq: barrier.endSeq)

    let newRange = try database.write { db in
      try db.performUndoRedo(startSeq: seqRange.startSeq, endSeq: seqRange.endSeq)
    }

    if let newRange {
      state.withValue {
        $0.barrierSeqRanges[barrier.id] = newRange
      }
    }
  }

  /// Temporarily disable undo tracking.
  ///
  /// Use this for bulk operations, migrations, or imports where you don't
  /// want individual changes tracked.
  func withUndoDisabled<T>(_ operation: () throws -> T) throws -> T {
    try database.write { db in
      try UndoState.find(1).update { $0.isActive = false }.execute(db)
    }
    defer {
      try? database.write { db in
        try UndoState.find(1).update { $0.isActive = true }.execute(db)
      }
    }
    return try operation()
  }
}
