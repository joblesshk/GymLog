import SwiftUI
import GymLogKit

/// Global confirmation alert for CONTRACT-UI.md §3.4's unsaved-work guard.
/// Attached once, high in the view tree (`ContentView`), so any entry point
/// that calls `ClientSwitchCoordinator.requestSwitch` -- the nav-bar
/// switcher, the 学员 tab list, anywhere else in the future -- gets the same
/// confirmation without each caller re-implementing the alert.
///
/// The coordinator is passed in explicitly (a plain stored property) rather
/// than read via `@Environment` inside this `ViewModifier`: an
/// `@Environment(ClientSwitchCoordinator.self)` read from inside `.alert`'s
/// own attribute-graph update (`MakeAlertStorage.updateValue()`) crashed at
/// launch with "No Observable object of type ClientSwitchCoordinator found"
/// even though `.environment(switchCoordinator)` was applied earlier in the
/// same modifier chain on `ContentView` -- an ordering/timing interaction
/// between `.environment()` and `.alert()`'s internal preference-computation
/// pass, not a logic bug in the guard itself. Taking the coordinator as an
/// explicit parameter sidesteps that interaction entirely.
private struct ClientSwitchConfirmationModifier: ViewModifier {
    let coordinator: ClientSwitchCoordinator

    func body(content: Content) -> some View {
        content.alert(
            L("切換學員將丟棄未保存的訓練記錄", "Switching clients will discard unsaved training data"),
            isPresented: Binding(
                get: { coordinator.pendingClientID != nil },
                set: { if !$0 { coordinator.cancelPendingSwitch() } }
            )
        ) {
            Button(L("取消", "Cancel"), role: .cancel) { coordinator.cancelPendingSwitch() }
            Button(L("放棄並切換", "Discard & Switch"), role: .destructive) { coordinator.confirmPendingSwitch() }
        } message: {
            Text(L("當前訓練記錄尚未保存，切換學員會丟棄這些內容。", "The current training record hasn't been saved yet — switching clients will discard it."))
        }
    }
}

extension View {
    func clientSwitchConfirmation(coordinator: ClientSwitchCoordinator) -> some View {
        modifier(ClientSwitchConfirmationModifier(coordinator: coordinator))
    }
}
