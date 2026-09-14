import Foundation
import Observation
import GymLogKit

/// Global current-client selection (CONTRACT-UI.md §3.4). Persisted via
/// `UserDefaults` directly rather than the `@AppStorage` property wrapper,
/// since this needs to live on a plain `@Observable` reference type shared
/// through the SwiftUI environment, not on a View -- so a cold launch
/// restores the coach's last-selected client.
@MainActor
@Observable
public final class CurrentClientStore {
    private static let storageKey = "gymlog.currentClientID"
    private let userDefaults: UserDefaults

    public var currentClientID: String? {
        didSet {
            guard currentClientID != oldValue else { return }
            userDefaults.set(currentClientID, forKey: Self.storageKey)
        }
    }

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.currentClientID = userDefaults.string(forKey: Self.storageKey)
    }

    /// Resolves the selected client against a live `@Query` result, falling
    /// back to the first client alphabetically when nothing is selected yet
    /// or the selected id no longer matches anyone (e.g. deleted).
    /// Ponytail review finding: this exact five-line lookup was duplicated
    /// verbatim across five view files (TodayView, HistoryListView,
    /// ExerciseLibraryView, SettingsView, ClientProfileView) -- centralized
    /// here so there's one place to change the fallback rule.
    public func currentClient(in clients: [Client]) -> Client? {
        if let id = currentClientID, let match = clients.first(where: { $0.id == id }) {
            return match
        }
        return clients.first
    }
}
