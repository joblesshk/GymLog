import Foundation
import Observation

/// Mediates every client switch through the unsaved-work guard
/// (CONTRACT-UI.md §3.4: "切换时若当前有未保存录入，必须弹确认，不得静默丢弃").
///
/// Deliberately a plain, SwiftUI-free coordinator so the guard logic is
/// directly unit-testable (`M2ClientSwitchGuardTests`) without going through
/// an alert/View round-trip: `requestSwitch` either switches immediately, or
/// parks the target in `pendingClientID` for a caller (the confirmation
/// alert) to resolve via `confirmPendingSwitch()`/`cancelPendingSwitch()`.
@MainActor
@Observable
public final class ClientSwitchCoordinator {
    public let clientStore: CurrentClientStore
    public let draftStore: TodayDraftStore

    /// Non-nil exactly while a confirmation is pending; drives the alert's
    /// `isPresented` binding.
    public var pendingClientID: String?

    public init(clientStore: CurrentClientStore, draftStore: TodayDraftStore) {
        self.clientStore = clientStore
        self.draftStore = draftStore
    }

    /// Attempts to switch the current client to `clientID`.
    /// - Returns: `true` if the switch happened immediately (no unsaved
    ///   work, or already the current client); `false` if a confirmation is
    ///   now pending (`pendingClientID` is set) and the switch has *not*
    ///   happened yet.
    @discardableResult
    public func requestSwitch(to clientID: String) -> Bool {
        guard clientID != clientStore.currentClientID else { return true }
        if draftStore.hasUnsavedWork {
            pendingClientID = clientID
            return false
        }
        performSwitch(to: clientID)
        return true
    }

    /// Coach chose "放弃并切换" in the confirmation alert.
    public func confirmPendingSwitch() {
        guard let clientID = pendingClientID else { return }
        performSwitch(to: clientID)
        pendingClientID = nil
    }

    /// Coach chose "取消" -- stays on the current client, draft untouched.
    public func cancelPendingSwitch() {
        pendingClientID = nil
    }

    private func performSwitch(to clientID: String) {
        clientStore.currentClientID = clientID
        draftStore.reset()
    }
}
