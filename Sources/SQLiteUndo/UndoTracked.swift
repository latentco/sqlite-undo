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

  /// INSERT trigger: Records a DELETE statement to undo the insert.
  private static func generateInsertTrigger(table: String) -> String {
    """
    CREATE TEMPORARY TRIGGER IF NOT EXISTS _undo_\(table)_insert
    AFTER INSERT ON "\(table)"
    WHEN "sqliteundo_isActive"()
    BEGIN
      INSERT INTO undolog(tableName, trackedRowid, sql)
      VALUES('\(table)', NEW.rowid, 'DELETE FROM "\(table)" WHERE rowid='||NEW.rowid);
    END
    """
  }

  /// UPDATE trigger: Records an UPDATE statement with old values.
  /// Uses BEFORE timing to capture true original values before cascading triggers fire.
  private static func generateUpdateTrigger(table: String, columns: [String]) -> String {
    // Build: col1='||quote(OLD.col1)||',col2='||quote(OLD.col2)||'...
    let setClauses = columns.map { col in
      "'\"\(col)\"='||quote(OLD.\"\(col)\")"
    }.joined(separator: "||','||")

    return """
      CREATE TEMPORARY TRIGGER IF NOT EXISTS _undo_\(table)_update
      BEFORE UPDATE ON "\(table)"
      WHEN "sqliteundo_isActive"()
      BEGIN
        INSERT INTO undolog(tableName, trackedRowid, sql)
        VALUES('\(table)', OLD.rowid, 'UPDATE "\(table)" SET '||\(setClauses)||' WHERE rowid='||OLD.rowid);
      END
      """
  }

  /// DELETE trigger: Records an INSERT statement with old values.
  /// Uses BEFORE timing to capture true original values before cascading triggers fire.
  private static func generateDeleteTrigger(table: String, columns: [String]) -> String {
    // Build column list: "col1","col2",...
    let columnList = columns.map { "\"\($0)\"" }.joined(separator: ",")

    // Build value expressions: quote(OLD.col1)||','||quote(OLD.col2)||...
    let valueExpressions = columns.map { col in
      "quote(OLD.\"\(col)\")"
    }.joined(separator: "||','||")

    return """
      CREATE TEMPORARY TRIGGER IF NOT EXISTS _undo_\(table)_delete
      BEFORE DELETE ON "\(table)"
      WHEN "sqliteundo_isActive"()
      BEGIN
        INSERT INTO undolog(tableName, trackedRowid, sql)
        VALUES('\(table)', OLD.rowid, 'INSERT INTO "\(table)"(rowid,\(columnList)) VALUES('||OLD.rowid||','||\(valueExpressions)||')');
      END
      """
  }
}
