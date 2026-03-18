import Foundation
import SQLiteData

extension StructuredQueries.Table {
  /// Generate and install undo triggers for this table.
  ///
  /// Creates three TEMPORARY triggers (INSERT, UPDATE, DELETE) that record
  /// reverse SQL into the undolog table. All triggers call the `sqliteundo_isActive()`
  /// database function before recording.
  public static func installUndoTriggers(_ db: Database) throws {
    let triggers = generateUndoTriggers()
    for sql in triggers {
      try #sql("\(raw: sql)").execute(db)
    }
  }

  /// Generate the SQL for the three undo triggers.
  static func generateUndoTriggers() -> [String] {
    let table = Self.tableName
    let columns = Self.TableColumns.allColumns.map(\.name)

    return [
      generateInsertTrigger(table: table),
      generateUpdateTrigger(table: table, columns: columns),
      generateDeleteTrigger(table: table, columns: columns),
    ]
  }

  /// INSERT trigger: Records a DELETE entry to undo the insert.
  private static func generateInsertTrigger(table: String) -> String {
    """
    CREATE TEMPORARY TRIGGER IF NOT EXISTS _undo_\(table)_insert
    AFTER INSERT ON "\(table)"
    WHEN "sqliteundo_isActive"()
    BEGIN
      INSERT INTO undolog(tableName, trackedRowid, sql)
      VALUES('\(table)', NEW.rowid, 'D'||char(9)||'\(table)'||char(9)||NEW.rowid);
    END
    """
  }

  /// UPDATE trigger: Records an UPDATE entry with only changed old values.
  /// Uses BEFORE timing to capture true original values before cascading triggers fire.
  /// The WHEN clause skips no-op updates entirely.
  private static func generateUpdateTrigger(table: String, columns: [String]) -> String {
    let changeChecks = columns.map { col in
      "OLD.\"\(col)\" IS NOT NEW.\"\(col)\""
    }.joined(separator: " OR ")

    let caseClauses = columns.map { col in
      "CASE WHEN OLD.\"\(col)\" IS NOT NEW.\"\(col)\" THEN char(9)||'\(col)'||char(9)||quote(OLD.\"\(col)\") ELSE '' END"
    }.joined(separator: "\n      || ")

    return """
      CREATE TEMPORARY TRIGGER IF NOT EXISTS _undo_\(table)_update
      BEFORE UPDATE ON "\(table)"
      WHEN "sqliteundo_isActive"()
        AND (\(changeChecks))
      BEGIN
        INSERT INTO undolog(tableName, trackedRowid, sql)
        VALUES('\(table)', OLD.rowid,
          'U'||char(9)||'\(table)'||char(9)||OLD.rowid
          || \(caseClauses)
        );
      END
      """
  }

  /// DELETE trigger: Records an INSERT entry with old values.
  /// Uses BEFORE timing to capture true original values before cascading triggers fire.
  private static func generateDeleteTrigger(table: String, columns: [String]) -> String {
    let colValuePairs = columns.map { col in
      "char(9)||'\(col)'||char(9)||quote(OLD.\"\(col)\")"
    }.joined(separator: "\n      || ")

    return """
      CREATE TEMPORARY TRIGGER IF NOT EXISTS _undo_\(table)_delete
      BEFORE DELETE ON "\(table)"
      WHEN "sqliteundo_isActive"()
      BEGIN
        INSERT INTO undolog(tableName, trackedRowid, sql)
        VALUES('\(table)', OLD.rowid,
          'I'||char(9)||'\(table)'||char(9)||OLD.rowid
          || \(colValuePairs)
        );
      END
      """
  }
}
