import Foundation
import OSLog
import SQLiteData

private let logger = Logger(subsystem: "SQLiteUndo", category: "UndoHistory")

extension Database {
  /// Execute reverse SQL for a barrier (undo operation).
  ///
  /// Following the sqlite.org/undoredo pattern:
  /// 1. Fetch the current entries for this barrier
  /// 2. Delete those entries
  /// 3. Execute the SQL in reverse order WITH triggers enabled
  /// 4. The triggers capture new reverse SQL (which becomes the redo SQL)
  ///
  /// Undo and redo are symmetric - both replace the barrier's entries
  /// with new reverse SQL captured during execution.
  func performUndo(barrier: UndoBarrier) throws {
    logger.debug("Performing undo: \(barrier.name) (\(barrier.startSeq)...\(barrier.endSeq))")

    // Fetch entries to execute (in reverse order for undo)
    let entries = try UndoLogEntry
      .where { $0.seq >= barrier.startSeq && $0.seq <= barrier.endSeq }
      .order { $0.seq.desc() }
      .fetchAll(self)

    // Delete the entries (they'll be replaced by new ones during execution)
    try deleteUndoLogEntries(from: barrier.startSeq, to: barrier.endSeq)

    // Reset the autoincrement to reuse the same sequence range
    try execute(sql: "DELETE FROM sqlite_sequence WHERE name='undolog'")
    try execute(sql: "INSERT INTO sqlite_sequence (name, seq) VALUES ('undolog', \(barrier.startSeq - 1))")

    // Execute with triggers ENABLED - this captures the redo SQL
    for entry in entries {
      logger.trace("Undo SQL: \(entry.sql)")
      try execute(sql: entry.sql)
    }
  }

  /// Execute reverse SQL for a barrier (redo operation).
  ///
  /// Same as undo - fetch, delete, execute with triggers enabled.
  /// The new captured SQL becomes the undo SQL again.
  func performRedo(barrier: UndoBarrier) throws {
    logger.debug("Performing redo: \(barrier.name) (\(barrier.startSeq)...\(barrier.endSeq))")

    // Fetch entries to execute (in reverse order - same as undo)
    let entries = try UndoLogEntry
      .where { $0.seq >= barrier.startSeq && $0.seq <= barrier.endSeq }
      .order { $0.seq.desc() }
      .fetchAll(self)

    // Delete the entries
    try deleteUndoLogEntries(from: barrier.startSeq, to: barrier.endSeq)

    // Reset the autoincrement to reuse the same sequence range
    try execute(sql: "DELETE FROM sqlite_sequence WHERE name='undolog'")
    try execute(sql: "INSERT INTO sqlite_sequence (name, seq) VALUES ('undolog', \(barrier.startSeq - 1))")

    // Execute with triggers ENABLED - this captures the undo SQL
    for entry in entries {
      logger.trace("Redo SQL: \(entry.sql)")
      try execute(sql: entry.sql)
    }
  }
}

extension Database {
  /// Get the current maximum sequence number in the undolog.
  func undoLogMaxSeq() throws -> Int? {
    try Int.fetchOne(self, sql: "SELECT MAX(seq) FROM undolog")
  }

  /// Delete undolog entries in a sequence range.
  func deleteUndoLogEntries(from startSeq: Int, to endSeq: Int) throws {
    try UndoLogEntry
      .where { $0.seq >= startSeq && $0.seq <= endSeq }
      .delete()
      .execute(self)
  }
}
