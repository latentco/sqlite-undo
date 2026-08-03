#if SQLiteUndoComposableArchitecture
  import ComposableArchitecture
  import DependenciesTestSupport
  import Foundation
  import SQLiteData
  import SQLiteUndo
  import StructuredQueries
  import Testing

  @Suite(
    .serialized
  )
  @MainActor
  struct ComposableArchitectureTests {

    @Test
    func effectUndoableCreatesBarrier() async throws {
      let testUndoManager = UndoManager()

      try await withDependencies {
        let database = try! makeTestDatabase()
        $0.defaultDatabase = database
        $0.installDefaultUndoStack(testUndoManager)
        $0.defaultUndoEngine = try! UndoEngine(for: database, tables: TestRecord.self)
      } operation: {
        @Dependency(\.defaultDatabase) var database

        let store = TestStore(initialState: TestFeature.State()) {
          TestFeature()
        }

        await store.send(.insertItem)
        await store.receive(\.itemInserted)

        let count = try await database.read { db in try TestRecord.all.fetchCount(db) }
        #expect(count == 1)
        #expect(testUndoManager.canUndo == true)
        #expect(testUndoManager.undoActionName == "Insert Item")
      }
    }

    @Test
    func effectUndoableUndoWorks() async throws {
      let testUndoManager = UndoManager()

      try await withDependencies {
        let database = try! makeTestDatabase()
        $0.defaultDatabase = database
        $0.installDefaultUndoStack(testUndoManager)
        $0.defaultUndoEngine = try! UndoEngine(for: database, tables: TestRecord.self)
      } operation: {
        @Dependency(\.defaultDatabase) var database

        let store = TestStore(initialState: TestFeature.State()) {
          TestFeature()
        }

        await store.send(.insertItem)
        await store.receive(\.itemInserted)

        let countBefore = try await database.read { db in try TestRecord.all.fetchCount(db) }
        #expect(countBefore == 1)

        testUndoManager.undo()

        let countAfter = try await database.read { db in try TestRecord.all.fetchCount(db) }
        #expect(countAfter == 0)
      }
    }

    /// `.task(id: undoManager)` re-fires whenever the environment's UndoManager changes
    /// identity, so `.set` arrives more than once and resubscribes to the event stream.
    @Test
    func resettingUndoManagerKeepsEventsFlowing() async throws {
      let testUndoManager = UndoManager()

      await withDependencies {
        let database = try! makeTestDatabase()
        $0.defaultDatabase = database
        $0.installDefaultUndoStack(testUndoManager)
        $0.defaultUndoEngine = try! UndoEngine(for: database, tables: TestRecord.self)
      } operation: {
        let store = TestStore(initialState: TestFeature.State()) {
          TestFeature()
        }

        let first = await store.send(.undoManager(.set(testUndoManager)))
        let second = await store.send(.undoManager(.set(testUndoManager)))

        await store.send(.insertItem)
        await store.receive(\.itemInserted)

        testUndoManager.undo()

        await store.receive(\.undoManager.event)

        await first.cancel()
        await second.cancel()
      }
    }

    /// Two windows, each with its own UndoStack and UndoManager, observe their own
    /// events independently — mounting the second leaves the first's subscription intact.
    @Test
    func eachWindowObservesItsOwnEventsIndependently() async throws {
      let managerA = UndoManager()
      let managerB = UndoManager()
      let stackA = UndoStack.live(managerA)
      let stackB = UndoStack.live(managerB)

      try await withDependencies {
        let database = try! makeTestDatabase()
        $0.defaultDatabase = database
        $0.defaultUndoEngine = try! UndoEngine(for: database, tables: TestRecord.self)
      } operation: {
        let storeA = withDependencies {
          $0.defaultUndoStack = stackA
        } operation: {
          TestStore(initialState: TestFeature.State()) { TestFeature() }
        }
        let storeB = withDependencies {
          $0.defaultUndoStack = stackB
        } operation: {
          TestStore(initialState: TestFeature.State()) { TestFeature() }
        }

        let subscriptionA = await storeA.send(.undoManager(.set(managerA)))
        let subscriptionB = await storeB.send(.undoManager(.set(managerB)))

        await storeA.send(.insertItem)
        await storeA.receive(\.itemInserted)

        managerA.undo()

        await storeA.receive(\.undoManager.event)

        await subscriptionA.cancel()
        await subscriptionB.cancel()
      }
    }
  }

  // MARK: - Test Feature

  @Reducer
  private struct TestFeature {
    @ObservableState
    struct State: Equatable {}

    enum Action: UndoManageableAction {
      case insertItem
      case itemInserted
      case undoManager(UndoManagingAction)
    }

    @Dependency(\.defaultDatabase) var database

    var body: some ReducerOf<Self> {
      UndoManagingReducer()
      Reduce { state, action in
        switch action {
        case .insertItem:
          return .run { [database] send in
            try await undoable("Insert Item") {
              try await database.write { db in
                try TestRecord.insert { TestRecord(id: 1, name: "Test") }.execute(db)
              }
            }
            await send(.itemInserted)
          }

        case .itemInserted:
          return .none

        case .undoManager:
          return .none
        }
      }
    }
  }

  // MARK: - Test Helpers

  @Table
  private struct TestRecord: Identifiable {
    @Column(primaryKey: true) var id: Int
    var name: String = ""
    var value: Int?
  }

  private func makeTestDatabase() throws -> any DatabaseWriter {
    let database = try DatabaseQueue(configuration: Configuration())

    try database.write { db in
      try db.execute(
        sql: """
          CREATE TABLE "testRecords" (
            "id" INTEGER PRIMARY KEY,
            "name" TEXT NOT NULL DEFAULT '',
            "value" INTEGER
          )
          """
      )
    }

    return database
  }
#endif
