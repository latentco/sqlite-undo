import ComposableArchitecture
import SQLiteUndo
import SQLiteUndoTCA
import SwiftUI

@main
struct UndoForMacOSApp: App {
  static let store = Store(
    initialState: DemoFeature.State()
  ) {
    DemoFeature()
  }
  init() {
    prepareDependencies {
      let database = try! makeDemoDatabase()
      $0.defaultDatabase = database
      $0.defaultUndoEngine = try! UndoEngine(
        for: database,
        tables: DemoItem.self
      )
    }
  }
  var body: some Scene {
    WindowGroup {
      DemoView(store: Self.store)
    }
  }
}

@Reducer
struct DemoFeature {
  @ObservableState
  struct State {
    @FetchAll(DemoItem.all) var items: [DemoItem]
  }

  enum Action: UndoManageableAction {
    case undoManager(UndoManagingAction)
    case addItem
    case addItemInBackground
    case addItemWithoutTracking
    case addUntrackedItem
    case incrementCount(Int)
    case incrementAll
    case deleteItem(Int)
  }

  @Dependency(\.defaultDatabase) var database
  @Dependency(\.defaultUndoEngine) var undoEngine

  var body: some Reducer<State, Action> {
    UndoManagingReducer()
    Reduce { state, action in
      switch action {
      case .undoManager:
        return .none

      case .addItem:
        withErrorReporting {
          try undoable("Add Item") {
            try database.write { db in
              let nextID = (try DemoItem.all.fetchAll(db).map(\.id).max() ?? 0) + 1
              try DemoItem.insert { DemoItem(id: nextID, name: "Item \(nextID)") }.execute(db)
            }
          }
        }
        return .none

      case .addItemInBackground:
        return .run { _ in
          try await undoable("Add Item (Background)") {
            try await database.write { db in
              let nextID = (try DemoItem.all.fetchAll(db).map(\.id).max() ?? 0) + 1
              try DemoItem.insert { DemoItem(id: nextID, name: "Item \(nextID)") }.execute(db)
            }
          }
        }

      case .addItemWithoutTracking:
        withErrorReporting {
          try withUndoDisabled {
            try database.write { db in
              let nextID = (try DemoItem.all.fetchAll(db).map(\.id).max() ?? 0) + 1
              try DemoItem.insert { DemoItem(id: nextID, name: "Item \(nextID)") }.execute(db)
            }
          }
        }
        return .none

      case .addUntrackedItem:
        withErrorReporting {
          try undoable("Add Untracked Item") {
            try database.write { db in
              try UntrackedDemoItem.insert { UntrackedDemoItem.Draft() }.execute(db)
            }
          }
        }
        return .none

      case .incrementCount(let id):
        withErrorReporting {
          try undoable("Increment Count") {
            try database.write { db in
              try DemoItem.find(id).update { $0.count += 1 }.execute(db)
            }
          }
        }
        return .none

      case .incrementAll:
        withErrorReporting {
          try undoable("Increment All") {
            try database.write { db in
              for item in try DemoItem.all.fetchAll(db) {
                try DemoItem.find(item.id).update { $0.count += 1 }.execute(db)
              }
            }
          }
        }
        return .none

      case .deleteItem(let id):
        withErrorReporting {
          try undoable("Delete Item") {
            try database.write { db in
              try DemoItem.find(id).delete().execute(db)
            }
          }
        }
        return .none
      }
    }
  }
}

struct DemoView: View {
  @Bindable var store: StoreOf<DemoFeature>
  @Environment(\.undoManager) var undoManager
  @State private var observableUndo = ObservableUndoManager()

  var body: some View {
    VStack(spacing: 16) {
      Text("SQLiteUndo Demo")
        .font(.headline)

      Text("Use Edit > Undo (⌘Z) and Redo (⇧⌘Z)")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack {
        Button("Undo") { observableUndo.undo() }.disabled(!observableUndo.canUndo)
        Button("Redo") { observableUndo.redo() }.disabled(!observableUndo.canRedo)
      }

      List {
        ForEach(store.items) { item in
          HStack {
            Text(item.name)
            Spacer()
            Text("Count: \(item.count)")
              .foregroundStyle(.secondary)
            Button("+") {
              store.send(.incrementCount(item.id))
            }
            .buttonStyle(.bordered)
            Button("Delete") {
              store.send(.deleteItem(item.id))
            }
            .buttonStyle(.bordered)
            .tint(.red)
          }
        }
      }
      .frame(minHeight: 200)

      VStack {
        HStack {
          Button("Add Item") {
            store.send(.addItem)
          }
          .buttonStyle(.borderedProminent)
          Button("Increment All") {
            store.send(.incrementAll)
          }
          .buttonStyle(.bordered)
          .disabled(store.items.isEmpty)
        }
        HStack {
          Button("Add Item without tracking") {
            store.send(.addItemWithoutTracking)
          }
          .buttonStyle(.bordered)
          Button("Add Item (Background)") {
            store.send(.addItemInBackground)
          }
          .buttonStyle(.bordered)
          Button("Add Untracked Item") {
            store.send(.addUntrackedItem)
          }
          .buttonStyle(.bordered)
        }
        .fixedSize()
      }
    }
    .padding()
    .frame(width: 400)
    .setUndoManager(store: store)
    .onChange(of: undoManager, initial: true) { _, newValue in observableUndo.set(newValue) }
  }
}

/// Makes UndoManager's canUndo/canRedo state observable by SwiftUI.
///
/// UndoManager doesn't participate in SwiftUI's observation system, so
/// changes to canUndo/canRedo don't trigger view updates. This wrapper
/// listens to NSUndoManager notifications and exposes observable properties.
@Observable
final class ObservableUndoManager {
  private(set) var canUndo = false
  private(set) var canRedo = false

  private var undoManager: UndoManager?
  private var observations: [Any] = []

  func set(_ undoManager: UndoManager?) {
    self.undoManager = undoManager
    observations.removeAll()
    guard let undoManager else {
      canUndo = false
      canRedo = false
      return
    }
    update()
    let nc = NotificationCenter.default
    let handler: (Notification) -> Void = { [weak self] _ in self?.update() }
    observations = [
      nc.addObserver(
        forName: .NSUndoManagerDidCloseUndoGroup,
        object: undoManager,
        queue: .main,
        using: handler
      ),
      nc.addObserver(
        forName: .NSUndoManagerDidUndoChange,
        object: undoManager,
        queue: .main,
        using: handler
      ),
      nc.addObserver(
        forName: .NSUndoManagerDidRedoChange,
        object: undoManager,
        queue: .main,
        using: handler
      ),
    ]
  }

  func undo() { undoManager?.undo() }
  func redo() { undoManager?.redo() }

  private func update() {
    canUndo = undoManager?.canUndo ?? false
    canRedo = undoManager?.canRedo ?? false
  }
}

@Table
struct DemoItem: Identifiable {
  var id: Int
  var name: String = ""
  var count: Int = 0
}

@Table
struct UntrackedDemoItem: Identifiable {
  var id: Int
}

func makeDemoDatabase() throws -> any DatabaseWriter {
  let database = try DatabaseQueue()

  try database.write { db in
    try #sql(
      """
      CREATE TABLE "demoItems" (
        "id" INTEGER PRIMARY KEY,
        "name" TEXT NOT NULL DEFAULT '',
        "count" INTEGER NOT NULL DEFAULT 0
      )
      """
    ).execute(db)
    try #sql(
      """
      CREATE TABLE "untrackedDemoItems" (
        "id" INTEGER PRIMARY KEY
      )
      """
    ).execute(db)
  }

  return database
}
