import XCTest
@testable import GymLogKit

/// CONTRACT-UI.md §3.4: "切换时若当前有未保存录入，必须弹确认，不得静默丢弃."
/// This is the one risk item the task brief explicitly says to "prove ...
/// with a test" -- so this file is entirely about the guard's state
/// machine: does an unsaved draft block an immediate switch, does
/// confirming actually switch and clear the draft, does cancelling leave
/// everything untouched.
@MainActor
final class M2ClientSwitchGuardTests: XCTestCase {

    private func makeExercise() -> Exercise {
        Exercise(id: "ex-1", canonicalName: "Bench press", aliases: [], movementPattern: .push, equipment: .barbell, loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 1, needsReview: false, reviewReason: nil)
    }

    func testSwitchesImmediatelyWhenNoUnsavedWork() {
        let clientStore = CurrentClientStore(userDefaults: UserDefaults(suiteName: #function)!)
        let draftStore = TodayDraftStore()
        let coordinator = ClientSwitchCoordinator(clientStore: clientStore, draftStore: draftStore)

        let switched = coordinator.requestSwitch(to: "cl-b")

        XCTAssertTrue(switched, "no unsaved work -> switch should happen immediately")
        XCTAssertEqual(clientStore.currentClientID, "cl-b")
        XCTAssertNil(coordinator.pendingClientID, "no confirmation should be pending")
    }

    func testDoesNotSwitchImmediatelyWhenDraftHasUnsavedEntries() {
        let clientStore = CurrentClientStore(userDefaults: UserDefaults(suiteName: #function)!)
        clientStore.currentClientID = "cl-a"
        let draftStore = TodayDraftStore()
        draftStore.startNew(clientID: "cl-a")
        draftStore.blocks.append(BlockDraft(entries: [EntryDraft(exercise: makeExercise(), setsCount: 3, load: .absolute(kg: 20, raw: "20"), targetQuantity: 10, actualQuantity: 10)]))
        XCTAssertTrue(draftStore.hasUnsavedWork, "sanity: draft must actually be considered unsaved for this test to mean anything")

        let coordinator = ClientSwitchCoordinator(clientStore: clientStore, draftStore: draftStore)
        let switched = coordinator.requestSwitch(to: "cl-b")

        XCTAssertFalse(switched, "unsaved work must block the immediate switch")
        XCTAssertEqual(clientStore.currentClientID, "cl-a", "current client must NOT have changed yet")
        XCTAssertEqual(coordinator.pendingClientID, "cl-b", "the target client must be parked pending confirmation")
        XCTAssertFalse(draftStore.blocks.isEmpty, "the draft must NOT have been silently discarded")
    }

    func testConfirmingPendingSwitchSwitchesAndClearsDraft() {
        let clientStore = CurrentClientStore(userDefaults: UserDefaults(suiteName: #function)!)
        clientStore.currentClientID = "cl-a"
        let draftStore = TodayDraftStore()
        draftStore.startNew(clientID: "cl-a")
        draftStore.blocks.append(BlockDraft(entries: [EntryDraft(exercise: makeExercise(), setsCount: 3, load: .absolute(kg: 20, raw: "20"), targetQuantity: 10, actualQuantity: 10)]))

        let coordinator = ClientSwitchCoordinator(clientStore: clientStore, draftStore: draftStore)
        coordinator.requestSwitch(to: "cl-b")
        coordinator.confirmPendingSwitch()

        XCTAssertEqual(clientStore.currentClientID, "cl-b", "confirming must actually perform the switch")
        XCTAssertNil(coordinator.pendingClientID)
        XCTAssertFalse(draftStore.hasUnsavedWork, "confirming a discard must clear the draft")
        XCTAssertTrue(draftStore.blocks.isEmpty)
    }

    func testCancellingPendingSwitchLeavesClientAndDraftUntouched() {
        let clientStore = CurrentClientStore(userDefaults: UserDefaults(suiteName: #function)!)
        clientStore.currentClientID = "cl-a"
        let draftStore = TodayDraftStore()
        draftStore.startNew(clientID: "cl-a")
        let entry = EntryDraft(exercise: makeExercise(), setsCount: 3, load: .absolute(kg: 20, raw: "20"), targetQuantity: 10, actualQuantity: 10)
        draftStore.blocks.append(BlockDraft(entries: [entry]))

        let coordinator = ClientSwitchCoordinator(clientStore: clientStore, draftStore: draftStore)
        coordinator.requestSwitch(to: "cl-b")
        coordinator.cancelPendingSwitch()

        XCTAssertEqual(clientStore.currentClientID, "cl-a", "cancelling must NOT switch clients")
        XCTAssertNil(coordinator.pendingClientID)
        XCTAssertEqual(draftStore.blocks.count, 1, "cancelling must preserve the unsaved draft exactly")
        XCTAssertEqual(draftStore.blocks.first?.entries.first?.id, entry.id)
    }

    func testRequestingTheAlreadyCurrentClientIsANoOpEvenWithUnsavedWork() {
        let clientStore = CurrentClientStore(userDefaults: UserDefaults(suiteName: #function)!)
        clientStore.currentClientID = "cl-a"
        let draftStore = TodayDraftStore()
        draftStore.startNew(clientID: "cl-a")
        draftStore.blocks.append(BlockDraft(entries: [EntryDraft(exercise: makeExercise(), setsCount: 3, load: .absolute(kg: 20, raw: "20"), targetQuantity: 10, actualQuantity: 10)]))

        let coordinator = ClientSwitchCoordinator(clientStore: clientStore, draftStore: draftStore)
        let switched = coordinator.requestSwitch(to: "cl-a")

        XCTAssertTrue(switched)
        XCTAssertNil(coordinator.pendingClientID, "switching to the already-current client must never prompt")
        XCTAssertFalse(draftStore.blocks.isEmpty, "and must never touch the draft")
    }

    // MARK: - CurrentClientStore persistence

    func testCurrentClientStorePersistsAcrossInstancesViaUserDefaults() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        let first = CurrentClientStore(userDefaults: defaults)
        first.currentClientID = "cl-persisted"

        let second = CurrentClientStore(userDefaults: defaults)
        XCTAssertEqual(second.currentClientID, "cl-persisted", "a fresh instance must restore the last-selected client (cold-launch restore)")
    }
}
