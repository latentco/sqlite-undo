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

/// Execute an operation within an undoable barrier.
///
/// ```swift
/// try undoable("Set Rating") {
///   try database.write { db in
///     try Item.find(id).update { $0.rating = rating }.execute(db)
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

/// Execute an async operation within an undoable barrier.
///
/// ```swift
/// try await undoable("Set Rating") {
///   try await database.write { db in
///     try Item.find(id).update { $0.rating = rating }.execute(db)
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

/// Execute an operation with undo tracking disabled.
///
/// Changes made within this block are not captured in the undo log.
/// Use this for programmatic operations that shouldn't be undoable
/// (e.g., initial app state, batch imports).
///
/// ```swift
/// try withUndoDisabled {
///   try database.write { db in
///     try Item.insert { Item(id: 1, name: "Imported") }.execute(db)
///   }
/// }
/// ```
public func withUndoDisabled<T>(_ operation: () throws -> T) throws -> T {
  try $_undoIsActive.withValue(false) {
    try operation()
  }
}

/// Execute an async operation with undo tracking disabled.
///
/// Changes made within this block are not captured in the undo log.
/// Use this for programmatic operations that shouldn't be undoable
/// (e.g., initial app state, batch imports).
///
/// ```swift
/// try await withUndoDisabled {
///   try await database.write { db in
///     try Item.insert { Item(id: 1, name: "Imported") }.execute(db)
///   }
/// }
/// ```
public func withUndoDisabled<T>(_ operation: @Sendable () async throws -> T) async throws -> T {
  try await $_undoIsActive.withValue(false) {
    try await operation()
  }
}
