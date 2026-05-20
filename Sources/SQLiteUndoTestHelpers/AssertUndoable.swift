import CustomDump
import Dependencies
import InlineSnapshotTesting
import SQLiteData
import SQLiteUndo
import SnapshotTestingCustomDump

/// Asserts that an operation is undoable by verifying:
/// 1. The database state before the operation (inline snapshot)
/// 2. The undo stack contains the expected action name
/// 3. The database state after the operation (inline snapshot)
/// 4. Performing undo restores the original database state
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@MainActor
public func assertUndoable<each V: QueryRepresentable, S: Statement<(repeat each V)>>(
  _ actionName: String,
  query: S,
  fileID: StaticString = #fileID,
  file: StaticString = #filePath,
  function: StaticString = #function,
  line: UInt = #line,
  column: UInt = #column,
  operation: () async throws -> Void,
  before: (() -> String)? = nil,
  after: (() -> String)? = nil
) async throws {
  @Dependency(\.defaultDatabase) var database
  @Dependency(\.defaultUndoStack) var undoStack

  // 1. Snapshot the before state
  let beforeTable = fetchTable(query, database: database)
  assertInlineSnapshot(
    of: beforeTable,
    as: .lines,
    message: "Before did not match",
    syntaxDescriptor: InlineSnapshotSyntaxDescriptor(
      trailingClosureLabel: "before",
      trailingClosureOffset: 1
    ),
    matches: before,
    fileID: fileID,
    file: file,
    function: function,
    line: line,
    column: column
  )

  // 2. Perform the operation
  try await operation()

  // 3. Verify the undo stack
  expectNoDifference(
    undoStack.currentState(),
    UndoStackState(undo: [actionName]),
    fileID: fileID,
    filePath: file,
    line: line,
    column: column
  )

  // 4. Snapshot the after state
  let afterTable = fetchTable(query, database: database)
  assertInlineSnapshot(
    of: afterTable,
    as: .lines,
    message: "After did not match",
    syntaxDescriptor: InlineSnapshotSyntaxDescriptor(
      trailingClosureLabel: "after",
      trailingClosureOffset: 2
    ),
    matches: after,
    fileID: fileID,
    file: file,
    function: function,
    line: line,
    column: column
  )

  // 5. Perform undo and verify it restores the original state
  do {
    try undoStack.performUndo()
  } catch {
    reportIssue(
      "Undo failed: \(error)",
      fileID: fileID,
      filePath: file,
      line: line,
      column: column
    )
    return
  }
  let afterUndoTable = fetchTable(query, database: database)
  expectNoDifference(
    afterUndoTable,
    beforeTable,
    "Undo did not restore the original state",
    fileID: fileID,
    filePath: file,
    line: line,
    column: column
  )
}

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
private func fetchTable<each V: QueryRepresentable, S: Statement<(repeat each V)>>(
  _ query: S,
  database: any DatabaseWriter
) -> String {
  do {
    let rows = try database.write { try query.fetchAll($0) }
    if rows.isEmpty {
      return "(No results)"
    }
    var table = ""
    printTable(rows, to: &table)
    return table
  } catch {
    return "(Error: \(error.localizedDescription))"
  }
}

private func printTable<each C>(
  _ rows: [(repeat each C)], to output: inout some TextOutputStream
) {
  var maxColumnSpan: [Int] = []
  var hasMultiLineRows = false
  for _ in repeat (each C).self {
    maxColumnSpan.append(0)
  }
  var table: [([[Substring]], maxRowSpan: Int)] = []
  for row in rows {
    var columns: [[Substring]] = []
    var index = 0
    var maxRowSpan = 0
    for column in repeat each row {
      defer { index += 1 }
      var cell = ""
      customDump(column, to: &cell)
      let lines = cell.split(separator: "\n")
      hasMultiLineRows = hasMultiLineRows || lines.count > 1
      maxRowSpan = max(maxRowSpan, lines.count)
      maxColumnSpan[index] = max(maxColumnSpan[index], lines.map(\.count).max() ?? 0)
      columns.append(lines)
    }
    table.append((columns, maxRowSpan))
  }
  guard !table.isEmpty else { return }
  output.write("┌─")
  output.write(
    maxColumnSpan
      .map { String(repeating: "─", count: $0) }
      .joined(separator: "─┬─")
  )
  output.write("─┐\n")
  for (offset, rowAndMaxRowSpan) in table.enumerated() {
    let (row, maxRowSpan) = rowAndMaxRowSpan
    for rowOffset in 0..<maxRowSpan {
      output.write("│ ")
      var line: [String] = []
      for (columns, maxColumnSpan) in zip(row, maxColumnSpan) {
        if columns.count <= rowOffset {
          line.append(String(repeating: " ", count: maxColumnSpan))
        } else {
          line.append(
            columns[rowOffset]
              + String(repeating: " ", count: maxColumnSpan - columns[rowOffset].count)
          )
        }
      }
      output.write(line.joined(separator: " │ "))
      output.write(" │\n")
    }
    if hasMultiLineRows, offset != table.count - 1 {
      output.write("├─")
      output.write(
        maxColumnSpan
          .map { String(repeating: "─", count: $0) }
          .joined(separator: "─┼─")
      )
      output.write("─┤\n")
    }
  }
  output.write("└─")
  output.write(
    maxColumnSpan
      .map { String(repeating: "─", count: $0) }
      .joined(separator: "─┴─")
  )
  output.write("─┘")
}
