import ComposableArchitecture
import Foundation
import SQLiteUndo

// MARK: - Effect.undoable

extension Effect where Action: Sendable {
  /// Wrap a database operation in an undoable barrier.
  ///
  /// Use this for simple, synchronous database operations that should be undoable:
  ///
  /// ```swift
  /// case .setRating(let rating):
  ///   return .undoable("Set Rating") {
  ///     @Dependency(\.defaultDatabase) var database
  ///     try database.write { db in
  ///       try ProjectItem.find(id).update { $0.rating = rating }.execute(db)
  ///     }
  ///   }
  /// ```
  ///
  /// The barrier is automatically cancelled if the operation throws.
  public static func undoable(
    _ actionName: String,
    operation: @escaping @Sendable () throws -> Void
  ) -> Effect<Action> {
    .run { _ in
      @Dependency(\.undoClient) var undoClient

      let barrierId = try undoClient.beginBarrier(actionName)
      do {
        try operation()
        try undoClient.endBarrier(barrierId)
      } catch {
        try undoClient.cancelBarrier(barrierId)
        throw error
      }
    }
  }
}

// MARK: - withUndoable

/// Execute a synchronous operation within an undoable barrier.
///
/// Use this in reducers for simple, inline undoable operations:
///
/// ```swift
/// case .setRating(let rating):
///   withUndoable("Set Rating") {
///     @Dependency(\.defaultDatabase) var database
///     try database.write { db in
///       try ProjectItem.find(id).update { $0.rating = rating }.execute(db)
///     }
///   }
///   return .none
/// ```
///
/// Errors are reported via `reportIssue` and the barrier is cancelled.
public func withUndoable(
  _ actionName: String,
  operation: () throws -> Void
) {
  @Dependency(\.undoClient) var undoClient

  do {
    let barrierId = try undoClient.beginBarrier(actionName)
    do {
      try operation()
      try undoClient.endBarrier(barrierId)
    } catch {
      try undoClient.cancelBarrier(barrierId)
      throw error
    }
  } catch {
    reportIssue(error)
  }
}
