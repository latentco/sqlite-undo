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

  var body: some View {
    VStack(spacing: 16) {
      Text("SQLiteUndo Demo")
        .font(.headline)

      Text("Use Edit > Undo (⌘Z) and Redo (⇧⌘Z)")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack {
        Button("Undo") { undoManager?.undo() }.disabled(!(undoManager?.canUndo ?? false))
        Button("Redo") { undoManager?.redo() }.disabled(!(undoManager?.canRedo ?? false))
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
    }
    .padding()
    .frame(width: 400)
    .setUndoManager(store: store)
  }
}

@Table
struct DemoItem: Identifiable {
  @Column(primaryKey: true) var id: Int
  var name: String = ""
  var count: Int = 0
}

func makeDemoDatabase() throws -> any DatabaseWriter {
  let database = try DatabaseQueue()

  try database.write { db in
    try db.execute(
      sql: """
        CREATE TABLE "demoItems" (
          "id" INTEGER PRIMARY KEY,
          "name" TEXT NOT NULL DEFAULT '',
          "count" INTEGER NOT NULL DEFAULT 0
        )
        """
    )
  }

  return database
}
