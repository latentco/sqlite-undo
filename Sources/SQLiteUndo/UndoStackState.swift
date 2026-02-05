/// Represents the current state of the undo/redo stacks.
///
/// Use this in tests to verify that undoable actions were registered correctly.
///
/// ```swift
/// await store.send(.primary(.setFave(true)))
/// expectNoDifference(
///   undoEngine.undoStackState(),
///   UndoStackState(undo: ["Add Fave"], redo: [])
/// )
/// ```
public struct UndoStackState: Equatable, Sendable {
  /// Names of actions that can be undone (next undo action first).
  public var undo: [String]

  /// Names of actions that can be redone (next redo action first).
  public var redo: [String]

  public init(undo: [String], redo: [String] = []) {
    self.undo = undo
    self.redo = redo
  }
}

extension UndoStackState: ExpressibleByArrayLiteral {
  public init(arrayLiteral elements: String...) {
    self.init(undo: elements)
  }
}
