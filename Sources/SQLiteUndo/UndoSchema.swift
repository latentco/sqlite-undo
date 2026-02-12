import Foundation
import SQLiteData

/// An entry in the undo log recording SQL to reverse a single change.
///
/// Each INSERT/UPDATE/DELETE trigger records a corresponding reverse operation
/// into this table. The `seq` column provides ordering for proper undo/redo.
@Table("undolog")
struct UndoLogEntry: Sendable {
  /// Auto-incrementing sequence number for ordering.
  var seq: Int
  /// The name of the table that was modified.
  var tableName: String
  /// The rowid of the tracked row, for deduplication during reconciliation.
  var trackedRowid: Int = 0
  /// The SQL statement to reverse the change.
  var sql: String
}

extension DatabaseWriter {
  func installUndoSystem() throws {
    try write { db in
      try #sql("DROP TABLE IF EXISTS undolog").execute(db)
      try #sql("DROP TABLE IF EXISTS undoState").execute(db)

      try #sql(
        """
        CREATE TABLE undolog (
          seq INTEGER PRIMARY KEY AUTOINCREMENT,
          tableName TEXT NOT NULL,
          trackedRowid INTEGER NOT NULL DEFAULT 0,
          sql TEXT NOT NULL
        )
        """
      ).execute(db)

      db.add(function: $undoIsActiveFunction)
      db.add(function: $undoIsReplayingFunction)
    }
  }
}
