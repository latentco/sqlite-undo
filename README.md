# SQLiteUndo

SQLite-based undo/redo for Swift apps using SQLiteData. Uses database triggers to capture changes automatically.

## Setup

```swift
prepareDependencies {
  $0.defaultDatabase = try! appDatabase()
  $0.defaultUndoEngine = try! UndoEngine(
    for: $0.defaultDatabase,
    tables: ProjectItem.self, ProjectEdit.self
  )
}
```

Tables must conform to `UndoTracked`:

```swift
@Table
struct ProjectItem: UndoTracked {
  @Column(primaryKey: true) var id: Int
  var name: String
}
```

## Usage

```swift
import SQLiteUndo
```

### Basic

```swift
try await undoable("Set Rating") {
  try await database.write { db in
    try ProjectItem.find(id).update { $0.rating = 5 }.execute(db)
  }
}
```

### With explicit barrier management

```swift
@Dependency(\.defaultUndoEngine) var undoEngine

let barrierId = try undoEngine.beginBarrier("Set Rating")
try database.write { db in
  try ProjectItem.find(id).update { $0.rating = 5 }.execute(db)
}
try undoEngine.endBarrier(barrierId)
```

## ComposableArchitecture/SwiftUI Integration

```swift
import SQLiteUndoTCA

@Reducer
struct MyFeature {
  @ObservableState
  struct State { }

  enum Action: UndoManagableAction {
    case undoManager(UndoManagingAction)
    case setRating(Int)
  }

  @Dependency(\.defaultDatabase) var database

  var body: some ReducerOf<Self> {
    UndoManagingReducer()
    Reduce { state, action in
      switch action {
      case .undoManager:
        return .none
      case .setRating(let rating):
        return .run { _ in
          try await undoable("Set Rating") {
            try await database.write { db in
              try Article.find(id).update { $0.rating = rating }.execute(db)
            }
          }
        }
      }
    }
  }
}

struct MyView: View {
  let store: StoreOf<MyFeature>

  var body: some View {
    // ...
  }
}
```
