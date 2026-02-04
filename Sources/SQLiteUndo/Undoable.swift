import Dependencies
import Foundation

/// Execute an async operation within an undoable barrier.
///
/// Use this for database operations that should be undoable:
///
/// ```swift
/// try await undoable("Set Rating") {
///   try await database.write { db in
///     try ProjectItem.find(id).update { $0.rating = rating }.execute(db)
///   }
/// }
/// ```
///
/// The barrier is automatically cancelled if the operation throws.
public func undoable<T: Sendable>(
  _ actionName: String,
  operation: @Sendable () async throws -> T
) async throws -> T {
  @Dependency(\.defaultUndoEngine) var undoEngine

  let barrierId = try undoEngine.beginBarrier(actionName)
  do {
    let result = try await operation()
    try undoEngine.endBarrier(barrierId)
    return result
  } catch {
    try undoEngine.cancelBarrier(barrierId)
    throw error
  }
}

/// Execute a synchronous operation within an undoable barrier.
///
/// Use this for simple, inline undoable operations:
///
/// ```swift
/// undoable("Set Rating") {
///   try database.write { db in
///     try ProjectItem.find(id).update { $0.rating = rating }.execute(db)
///   }
/// }
/// ```
///
/// The barrier is automatically cancelled if the operation throws.
public func undoable(
  _ actionName: String,
  operation: () throws -> Void
) throws {
  @Dependency(\.defaultUndoEngine) var undoEngine

  let barrierId = try undoEngine.beginBarrier(actionName)
  do {
    try operation()
    try undoEngine.endBarrier(barrierId)
  } catch {
    try undoEngine.cancelBarrier(barrierId)
    throw error
  }
}
