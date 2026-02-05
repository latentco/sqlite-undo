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
  /// The SQL statement to reverse the change.
  var sql: String
}

/// Singleton row tracking whether undo tracking is active.
///
/// This table always contains exactly one row (id=1).
/// Stack management is handled by NSUndoManager, not stored in the database.
@Table("undoState")
struct UndoState: Sendable {
  /// Always 1 (singleton constraint)
  var id: Int = 1
  /// Whether undo tracking triggers are active.
  var isActive: Bool = true
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
          sql TEXT NOT NULL
        )
        """
      ).execute(db)

      try #sql(
        """
        CREATE TABLE undoState (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          isActive INTEGER NOT NULL DEFAULT 1
        )
        """
      ).execute(db)

      try #sql("INSERT INTO undoState (id, isActive) VALUES (1, 1)").execute(db)
    }
  }
}
