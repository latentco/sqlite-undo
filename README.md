# SQLiteUndo

[![CI](https://github.com/latentco/sqlite-undo/actions/workflows/ci.yml/badge.svg)](https://github.com/latentco/sqlite-undo/actions/workflows/ci.yml)

> **Status:** This library is used in production by [Aphera](https://aphera.co) but is under active development. APIs may change.

SQLite-based undo/redo for Swift apps using [SQLiteData](https://github.com/pointfreeco/sqlite-data) and [StructuredQueries](https://github.com/pointfreeco/swift-structured-queries). Uses database triggers to automatically capture reverse SQL for all changes to tracked tables, following the pattern described in [Automatic Undo/Redo Using SQLite](https://www.sqlite.org/undoredo.html).

Changes are grouped into barriers that represent single user actions (e.g., "Set Rating", "Delete Item"). Barriers integrate with `NSUndoManager` so undo/redo works with the standard Edit menu, keyboard shortcuts, and shake-to-undo.

A single **SQLiteUndo** library is provided: the core undo engine, barriers, and free functions (`undoable`, `withUndoDisabled`). [ComposableArchitecture](https://github.com/pointfreeco/swift-composable-architecture) integration for `UndoManager` wiring in SwiftUI ships in the same library, behind a package trait.

## Adding SQLiteUndo as a dependency

Add the following to your `Package.swift`:

```swift
.package(url: "https://github.com/latentco/sqlite-undo.git", from: "0.1.0"),
```

Then add the product to your target's dependencies:

```swift
.product(name: "SQLiteUndo", package: "sqlite-undo"),
```

### ComposableArchitecture support

The ComposableArchitecture integration is gated behind the `ComposableArchitecture` trait, which is **off by default**. Apps that don't use the Composable Architecture never resolve it as a dependency at all. To opt in, enable the trait on the package dependency:

```swift
.package(
  url: "https://github.com/latentco/sqlite-undo.git",
  from: "0.1.0",
  traits: ["ComposableArchitecture"]
),
```

SQLiteUndo declares no default traits, so this is the complete trait set — there is nothing else to re-enable alongside it.

In an Xcode project, traits are selected on the package dependency itself rather than in `Package.swift`: choose the package under **Package Dependencies** and enable the trait in its Traits picker. This requires Xcode 26.5 or later, which is when trait selection was added to the project format.

## Setup

```swift
prepareDependencies {
  $0.defaultDatabase = try! appDatabase()
  $0.defaultUndoEngine = try! UndoEngine(
    for: $0.defaultDatabase,
    tables: Article.self, Author.self
  )
}
```

Pass any `@Table` types to track:

```swift
@Table
struct Article {
  let id: Int
  var name: String
}
```

## Usage

```swift
import SQLiteUndo

try await undoable("Set Rating") {
  try await database.write { db in
    try Article.find(id).update { $0.rating = 5 }.execute(db)
  }
}
```

### Disabling undo tracking

Use `withUndoDisabled` for operations that shouldn't be undoable (e.g., batch imports, programmatic state rebuilds):

```swift
try withUndoDisabled {
  try database.write { db in
    try Article.insert { Article(id: 1, name: "Imported") }.execute(db)
  }
}
```

### Application triggers

The undo system uses BEFORE triggers to capture original row values before any cascade can modify them, and reconciles duplicate entries automatically. Same-table cascading triggers (e.g., enforcing "only one row can be primary") generally work without special handling because the undo log captures all affected rows and reconciliation keeps the true originals.

However, if your app has triggers that produce **side effects on other undo-tracked tables** (e.g., incrementing a counter on table B when table A is updated), you must suppress them during replay with `UndoEngine.isReplaying()`. Otherwise the side effect fires again during undo/redo, corrupting the restored state.

```swift
Article.createTemporaryTrigger(
  after: .update { $0.status },
  forEachRow: { old, new in
    // Side effect on a different table — needs isReplaying guard
    AuditLog.insert { AuditLog(articleId: new.id, action: "updated") }
  },
  when: { old, new in
    !UndoEngine.isReplaying()
  }
)
```

Or in raw SQL:

```sql
CREATE TRIGGER audit_article_update
AFTER UPDATE OF "status" ON "articles"
WHEN NOT "sqliteundo_isReplaying"()
BEGIN
  INSERT INTO "auditLog" ("articleId", "action") VALUES (NEW."id", 'updated');
END
```

### What a barrier captures

A barrier claims exactly the writes made inside its `undoable` block. Barriers may
overlap freely — concurrent barriers, or one opened inside another, each keep their
own changes, and undoing one never disturbs another.

Only writes made inside a barrier are tracked. A write outside one is applied
normally but is not undoable:

```swift
try database.write { db in                       // not undoable
  try Article.find(id).update { $0.rating = 5 }.execute(db)
}

try undoable("Set Rating") {                     // undoable
  try database.write { db in
    try Article.find(id).update { $0.rating = 5 }.execute(db)
  }
}
```

Tracking follows Swift's structured concurrency, so it reaches through `async`
writes and child tasks. It does not reach into a `Task.detached`, whose writes are
outside the barrier and therefore untracked.

### Undo events

After each undo/redo, the `UndoStack` that performed it emits an `UndoEvent` with the affected table rows. Use this to drive UI responses like scrolling to a restored item or switching views.

```swift
@Dependency(\.defaultUndoStack) var undoStack

for await event in undoStack.events() {
  if let articleIds = event.ids(for: Article.self) {
    // scroll to restored articles
  }
  if let authorIds = event.ids(for: Author.self) {
    // handle affected authors
  }
}
```

`ids(for:)` returns `nil` when no rows of that table were affected, so `if let` naturally gates your response logic.

Events are scoped to the stack that performed the undo, so an undo in one window does not notify another. See [Multiple windows](#multiple-windows).

## ComposableArchitecture/SwiftUI Integration

Requires the `ComposableArchitecture` trait — see [ComposableArchitecture support](#composablearchitecture-support).

```swift
import ComposableArchitecture
import SQLiteUndo

@Reducer
struct MyFeature {
  @ObservableState
  struct State { }

  enum Action: UndoManageableAction { // ✅ integrate the store for UndoManager registration
    case undoManager(UndoManagingAction)
    case setRating(Int)
  }

  @Dependency(\.defaultDatabase) var database

  var body: some ReducerOf<Self> {
    UndoManagingReducer()
    Reduce { state, action in
      switch action {
      case .undoManager(.event(let event)): // ✅ respond to undo/redo events
        if let articleIds = event.ids(for: Article.self) {
          // navigate to affected articles
        }
        return .none
      case .undoManager:
        return .none
      case .setRating(let rating):
        try undoable("Set Rating") { // ✅ wrap db operations in undoable
          try database.write { db in
            try Article.find(id).update { $0.rating = rating }.execute(db)
          }
        }
        return .none
      }
    }
  }
}

struct MyView: View {
  let store: StoreOf<MyFeature>
  var body: some View {
    VStack {
      // ... 
    }
    .setUndoManager(store: store) // ✅ pass the view's UndoManager to the system
  }
}
```

## Multiple windows

An undo scope is one `UndoStack` bound to one `UndoManager`. The database, engine, and
undo log are app-wide; the stack is not.

Give each window its own stack by scoping the dependency where its store is created:

```swift
struct MyWindow: View {
  @State private var store = withDependencies {
    $0.installDefaultUndoStack()
  } operation: {
    Store(initialState: MyFeature.State()) { MyFeature() }
  }

  var body: some View {
    MyView(store: store)
  }
}
```

The default stack is already app-wide, so a single-window app needs no setup at all. `installDefaultUndoStack()` exists to create an *additional* scope — call it once per window.

Each window then has its own undo/redo stack, its own Edit menu state, and its own
event stream. Barriers register with whichever stack is current when they close, and
undoing in one window never touches another's changes.

Because AppKit resolves `UndoManager` up the responder chain, this also gives you the
document case for free: several windows onto one `NSDocument` resolve to the *same*
`UndoManager`, so give them the same stack and they correctly share one undo history.

## Development

Because the ComposableArchitecture trait is off by default, `swift test` exercises only the core engine. Run the suite both ways:

```sh
swift test                     # core engine, trait off
swift test --enable-all-traits # adds the ComposableArchitecture tests
```

CI runs both, in debug and release. Building with the trait off is what catches ComposableArchitecture symbols leaking outside their `#if ComposableArchitecture` guards.

Xcode offers no way to select traits for a package you have opened directly — traits are chosen on a dependency edge, and a root package has none. To work on the trait-gated code in Xcode, uncomment the `|| true` in `Package.swift` to force the trait on locally. Leaving it uncommitted matters: with the trait forced on, the trait-off path stops being compiled anywhere.

## License

This library is released under the MIT license. See [LICENSE](LICENSE) for details.
