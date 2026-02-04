import CasePaths
import ComposableArchitecture
import Foundation
import SQLiteUndo
import SwiftUI

/// Protocol for actions that can receive the UndoManager from the view layer.
///
/// Conform your feature's Action to this protocol:
///
/// ```swift
/// @Reducer struct MyFeature {
///   enum Action: UndoManaging {
///     case undoManager(UndoManagingAction)
///     // ... other actions
///   }
///
///   var body: some Reducer<State, Action> {
///     UndoManagingReducer()
///     Reduce { state, action in
///       // ...
///     }
///   }
/// }
/// ```
///
/// Then set the undo manager in your view:
///
/// ```swift
/// ContentView(store: store)
///   .setUndoManager(store: store)
/// ```
public protocol UndoManaging {
  static func undoManager(_ action: UndoManagingAction) -> Self
}

/// Action for managing the UndoManager connection.
@CasePathable
public enum UndoManagingAction: Sendable {
  case set(UndoManager?)
}

/// A reducer that handles `UndoManaging` actions by setting the UndoManager on the UndoClient.
///
/// Compose this into your feature like `BindingReducer`:
///
/// ```swift
/// var body: some Reducer<State, Action> {
///   UndoManagingReducer()
///   Reduce { state, action in
///     // ...
///   }
/// }
/// ```
public struct UndoManagingReducer<State, Action: UndoManaging>: Reducer {
  @Dependency(\.undoClient) var undoClient
  public init() {}
  public var body: some Reducer<State, Action> {
    Reduce { state, action in
      guard let undoAction = AnyCasePath(unsafe: Action.undoManager).extract(from: action) else {
        return .none
      }
      switch undoAction {
      case .set(let manager):
        undoClient.setUndoManager(manager)
      }
      return .none
    }
  }
}

extension View {
  /// Sets the view's UndoManager on the store's undo system.
  ///
  /// Call this on your root view to connect the window's UndoManager:
  ///
  /// ```swift
  /// ContentView(store: store)
  ///   .setUndoManager(store: store)
  /// ```
  public func setUndoManager<State, Action: UndoManaging>(
    store: Store<State, Action>
  ) -> some View {
    modifier(SetUndoManagerModifier(store: store))
  }
}

struct SetUndoManagerModifier<State, Action: UndoManaging>: ViewModifier {
  @Environment(\.undoManager) var undoManager
  let store: Store<State, Action>

  func body(content: Content) -> some View {
    content
      .onAppear {
        store.send(.undoManager(.set(undoManager)))
      }
      .onChange(of: undoManager) { newValue in
        store.send(.undoManager(.set(newValue)))
      }
  }
}
