import Foundation
import StructuredQueries
import Testing

@testable import SQLiteUndo

@Suite(.serialized)
struct UndoBenchmarkTests {

  @Test(.disabled("Run manually for benchmarking"))
  func benchmarkUndoRedo() throws {
    let rowCounts = [100, 500, 1000, 2000]

    for count in rowCounts {
      let unbatched = try measure(rows: count, batched: false)
      let batched = try measure(rows: count, batched: true)
      let speedup = unbatched / batched
      print(
        "  \(count) rows — unbatched: \(fmt(unbatched))  batched: \(fmt(batched))  speedup: \(String(format: "%.1fx", speedup))"
      )
    }
  }
}

private func measure(rows: Int, batched: Bool) throws -> Double {
  let iterations = 3
  var total: Double = 0

  for _ in 0..<iterations {
    let (database, engine) = try makeUndoBenchmarkDatabase()

    // Insert rows in one barrier
    let barrierId = try engine.beginBarrier("Insert")
    try database.write { db in
      for i in 1...rows {
        try BenchRecord.insert { BenchRecord(id: i, name: "Item \(i)", value: i) }.execute(db)
      }
    }
    let barrier = try engine.endBarrier(barrierId)!

    _undoBatchingDisabled = !batched

    let clock = ContinuousClock()
    let elapsed = try clock.measure {
      try engine.performUndo(barrier: barrier)
      try engine.performRedo(barrier: barrier)
    }

    _undoBatchingDisabled = false
    total += Double(elapsed.components.attoseconds) / 1e18
  }

  return total / Double(iterations)
}

private func fmt(_ seconds: Double) -> String {
  if seconds < 0.001 {
    return String(format: "%.1f µs", seconds * 1_000_000)
  } else if seconds < 1 {
    return String(format: "%.1f ms", seconds * 1000)
  } else {
    return String(format: "%.2f s", seconds)
  }
}

@Table("benchRecords")
private struct BenchRecord: Identifiable {
  @Column(primaryKey: true) var id: Int
  var name: String = ""
  var value: Int?
}

private func makeUndoBenchmarkDatabase() throws -> (any DatabaseWriter, UndoCoordinator) {
  let database = try DatabaseQueue(configuration: Configuration())
  try database.write { db in
    try db.execute(
      sql: """
        CREATE TABLE "benchRecords" (
          "id" INTEGER PRIMARY KEY,
          "name" TEXT NOT NULL DEFAULT '',
          "value" INTEGER
        )
        """
    )
  }
  try database.installUndoSystem()
  try database.write { db in
    for sql in BenchRecord.generateUndoTriggers() {
      try db.execute(sql: sql)
    }
  }
  return (database, UndoCoordinator(database: database))
}
