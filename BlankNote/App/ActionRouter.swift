import Foundation
import Observation

/// Something asked of the app from outside a window: a global hotkey, Siri, Spotlight, the
/// Action Button or a Shortcut.
enum AppAction: Equatable {
    case newNote(text: String?)
    case search(String?)
}

/// Hands outside requests to the window the user last worked in. A request that arrives before
/// any window is ready (a cold launch from Siri) waits until one is.
@MainActor @Observable
final class ActionRouter {
    static let shared = ActionRouter()

    private(set) var pending: AppAction?
    /// Bumped with every request, so windows notice repeats of the same one.
    private(set) var requestCount = 0
    /// The most recently active window's navigator.
    @ObservationIgnored weak var activeNavigator: Navigator?

    func post(_ action: AppAction) {
        pending = action
        requestCount += 1
    }

    /// The pending request, if it's this window's to handle.
    func take(for navigator: Navigator) -> AppAction? {
        guard let action = pending, activeNavigator == nil || activeNavigator === navigator else { return nil }
        pending = nil
        return action
    }
}
