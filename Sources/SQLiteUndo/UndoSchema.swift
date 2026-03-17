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
  /// The parsed undo entry to reverse the change.
  var sql: UndoSQL
}

/// Parsed representation of trigger-generated undo entries.
/// Single-element arrays when stored; batching merges consecutive same-key entries.
enum UndoSQL: Equatable, Sendable {
  case delete(DeleteSQL)
  case insert(InsertSQL)
  case update(UpdateSQL)

  struct DeleteSQL: Equatable, Sendable {
    var table: String
    var rowids: [String]
  }

  struct InsertSQL: Equatable, Sendable {
    var table: String
    var columns: [String]
    var rows: [Row]

    struct Row: Equatable, Sendable {
      var rowid: String
      var values: [String]
    }
  }

  struct UpdateSQL: Equatable, Sendable {
    var table: String
    var assignments: [Assignment]
    var rowids: [String]

    struct Assignment: Equatable, Sendable {
      var column: String
      var value: String
    }
  }
}

extension UndoSQL: _OptionalPromotable {}

extension UndoSQL: QueryDecodable {
  init(decoder: inout some QueryDecoder) throws {
    guard let text = try decoder.decode(String.self),
      let parsed = UndoSQL(tabDelimited: text)
    else { throw QueryDecodingError.missingRequiredColumn }
    self = parsed
  }
}

extension UndoSQL: QueryRepresentable {}

extension UndoSQL: QueryExpression {
  typealias QueryValue = Self
}

extension UndoSQL: QueryBindable {
  var queryBinding: QueryBinding { .text(self.tabDelimited) }
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
