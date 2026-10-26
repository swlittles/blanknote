import InkwellCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Carries a Format menu command down the responder chain to whichever editor has focus.
final class FormatCommand: NSObject {
    let action: FormatAction

    init(_ action: FormatAction) {
        self.action = action
    }

    @MainActor
    static func send(_ action: FormatAction) {
        let selector = #selector(InkTextView.performFormatCommand(_:))
        #if os(macOS)
        NSApp.sendAction(selector, to: nil, from: FormatCommand(action))
        #else
        UIApplication.shared.sendAction(selector, to: nil, from: FormatCommand(action), for: nil)
        #endif
    }
}
