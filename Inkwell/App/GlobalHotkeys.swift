#if os(macOS)
import AppKit
import Carbon.HIToolbox
import InkwellCore
import Observation

/// Mac hotkeys that work in any app: show or hide Inkwell, start a note, search.
///
/// Uses Carbon's `RegisterEventHotKey`, which needs no Accessibility permission and works in the
/// sandbox. Registrations follow the `ShortcutStore`, and pause while a shortcut is being recorded.
@MainActor @Observable
final class GlobalHotkeys {
    static let shared = GlobalHotkeys()

    /// How many hotkeys are registered right now.
    var registeredCount: Int { registered.count }

    /// Hotkeys another app already holds, so they couldn't be registered.
    private(set) var failures: Set<ShortcutAction> = []
    /// Opens a main window when none is open (set by the first window, from SwiftUI's `openWindow`).
    @ObservationIgnored var openMainWindow: (() -> Void)?

    @ObservationIgnored private var shortcuts: ShortcutStore?
    @ObservationIgnored private var registered: [EventHotKeyRef] = []
    @ObservationIgnored private var actions: [UInt32: ShortcutAction] = [:]
    @ObservationIgnored private var handler: EventHandlerRef?
    private static let signature: OSType = 0x494E_4B57 // "INKW"

    func start(with shortcuts: ShortcutStore) {
        guard self.shortcuts == nil else { return }
        self.shortcuts = shortcuts
        installHandler()
        follow()
    }

    /// Re-registers now and whenever the shortcuts change.
    private func follow() {
        withObservationTracking {
            register()
        } onChange: {
            Task { @MainActor in GlobalHotkeys.shared.follow() }
        }
    }

    private func register() {
        for ref in registered { UnregisterEventHotKey(ref) }
        registered.removeAll()
        actions.removeAll()
        guard let shortcuts else { return }
        var failures: Set<ShortcutAction> = []
        for (index, action) in ShortcutAction.allCases.filter(\.isGlobal).enumerated() {
            guard let combo = shortcuts.activeCombo(for: action), let keyCode = combo.keyCode else { continue }
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(keyCode), Self.carbonModifiers(combo.modifiers), id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registered.append(ref)
                actions[id.id] = action
            } else {
                failures.insert(action)
            }
        }
        // Only while not recording: during recording nothing is registered on purpose.
        if !shortcuts.isRecording, failures != self.failures { self.failures = failures }
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            // Carbon delivers hotkeys on the main thread.
            MainActor.assumeIsolated { GlobalHotkeys.shared.fire(id.id) }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    func fire(_ id: UInt32) {
        guard let action = actions[id] else { return }
        perform(action)
    }

    func perform(_ action: ShortcutAction) {
        switch action {
        case .globalToggleApp:
            if NSApp.isActive, hasVisibleWindow {
                NSApp.hide(nil)
            } else {
                bringForward()
            }
        case .globalNewNote:
            bringForward()
            ActionRouter.shared.post(.newNote(text: nil))
        case .globalSearch:
            bringForward()
            ActionRouter.shared.post(.search(nil))
        default:
            break
        }
    }

    private var hasVisibleWindow: Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
    }

    private func bringForward() {
        NSApp.unhide(nil)
        NSApp.activate()
        if let minimized = NSApp.windows.first(where: { $0.isMiniaturized && $0.canBecomeMain }), !hasVisibleWindow {
            minimized.deminiaturize(nil)
        }
        if !hasVisibleWindow { openMainWindow?() }
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    private static func carbonModifiers(_ modifiers: KeyCombo.Modifiers) -> UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        return UInt32(flags)
    }
}
#endif
