import Dependencies
import Foundation
import SQLiteData

extension DatabaseWriter {
  /// Execute a write operation within an undoable barrier.
  ///
  /// This combines barrier management with the database write in a single call:
  ///
  /// ```swift
  /// try database.undoableWrite("Set Rating") { db in
  ///   try Article.find(id).update { $0.rating = 5 }.execute(db)
  /// }
  /// ```
  ///
  /// The barrier is automatically cancelled if the operation throws.
  public func undoableWrite<T>(
    _ actionName: String,
    operation: (Database) throws -> T
  ) throws -> T {
    @Dependency(\.defaultUndoEngine) var undoEngine

    let barrierId = try undoEngine.beginBarrier(actionName)
    do {
      let result = try write(operation)
      try undoEngine.endBarrier(barrierId)
      return result
    } catch {
      try undoEngine.cancelBarrier(barrierId)
      throw error
    }
  }

  /// Execute an async write operation within an undoable barrier.
  ///
  /// This combines barrier management with the database write in a single call:
  ///
  /// ```swift
  /// try await database.undoableWrite("Set Rating") { db in
  ///   try Article.find(id).update { $0.rating = 5 }.execute(db)
  /// }
  /// ```
  ///
  /// The barrier is automatically cancelled if the operation throws.
  public func undoableWrite<T: Sendable>(
    _ actionName: String,
    operation: @Sendable (Database) throws -> T
  ) async throws -> T {
    @Dependency(\.defaultUndoEngine) var undoEngine

    let barrierId = try undoEngine.beginBarrier(actionName)
    do {
      let result = try await write(operation)
      try undoEngine.endBarrier(barrierId)
      return result
    } catch {
      try undoEngine.cancelBarrier(barrierId)
      throw error
    }
  }
}

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
public func undoable<T>(
  _ actionName: String,
  operation: () throws -> T
) throws -> T {
  @Dependency(\.defaultUndoEngine) var undoEngine

  let barrierId = try undoEngine.beginBarrier(actionName)
  do {
    let result = try operation()
    try undoEngine.endBarrier(barrierId)
    return result
  } catch {
    try undoEngine.cancelBarrier(barrierId)
    throw error
  }
}
