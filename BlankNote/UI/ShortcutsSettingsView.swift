import BlankNoteCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Settings › Keyboard Shortcuts: every action with its shortcut, each one changeable.
struct ShortcutsSettingsView: View {
    @Environment(ShortcutStore.self) private var shortcuts

    var body: some View {
        Form {
            ForEach(groups, id: \.self) { group in
                Section {
                    ForEach(actions(in: group), id: \.self) { action in
                        LabeledContent(action.title) {
                            ShortcutRecorder(action: action)
                        }
                    }
                } header: {
                    Text(group.rawValue)
                } footer: {
                    if group == .global {
                        Text("These work in any app, even when BlankNote is in the background.")
                    }
                }
            }
            Section {
                Button("Restore All Defaults", role: .destructive) { shortcuts.resetAll() }
                    .disabled(shortcuts.overrides.isEmpty)
            } footer: {
                Text("Click a shortcut, then press the new keys. Press Delete to remove it, or Escape to cancel.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Keyboard Shortcuts")
    }

    private var groups: [ShortcutAction.Group] {
        #if os(macOS)
        ShortcutAction.Group.allCases
        #else
        ShortcutAction.Group.allCases.filter { $0 != .global }
        #endif
    }

    private func actions(in group: ShortcutAction.Group) -> [ShortcutAction] {
        ShortcutAction.allCases.filter { action in
            #if os(macOS)
            action.group == group
            #else
            action.group == group && !action.isMacOnly
            #endif
        }
    }
}

extension Notification.Name {
    /// Posted when a recorder starts, with its action's raw value, so any other one stops.
    static let shortcutRecorderStarted = Notification.Name("ShortcutRecorderStarted")
}

/// Shows an action's shortcut; click it, then press keys to change it.
struct ShortcutRecorder: View {
    let action: ShortcutAction
    @Environment(ShortcutStore.self) private var shortcuts
    @State private var recording = false
    @State private var message: String?
    #if os(macOS)
    @State private var monitor: Any?
    @State private var resignObserver: (any NSObjectProtocol)?
    #endif

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 6) {
                if shortcuts.isCustomized(action), !recording {
                    Button {
                        shortcuts.reset(action)
                        message = nil
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Restore \(action.defaultCombo?.displayString ?? "the default")")
                    .accessibilityLabel("Restore Default")
                }
                Button(action: toggleRecording) {
                    Text(label)
                        .monospacedDigit()
                        .foregroundStyle(recording || shortcuts.combo(for: action) != nil ? .primary : .secondary)
                        .frame(minWidth: 92)
                }
                .buttonStyle(.bordered)
                .tint(recording ? Palette.accentColor : nil)
                .accessibilityIdentifier("shortcut.\(action.rawValue)")
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isInUseElsewhere {
                Text("In use by another app")
                    .font(.caption)
                    .foregroundStyle(Color(Palette.danger))
            }
        }
        #if os(iOS)
        .background(KeyCapture(isActive: recording) { handle($0) })
        #endif
        .onDisappear { stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: .shortcutRecorderStarted)) { note in
            if note.object as? String != action.rawValue { stopRecording() }
        }
    }

    private var label: String {
        recording ? "Type Shortcut…" : shortcuts.combo(for: action)?.displayString ?? "None"
    }

    private var isInUseElsewhere: Bool {
        #if os(macOS)
        action.isGlobal && GlobalHotkeys.shared.failures.contains(action)
        #else
        false
        #endif
    }

    private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        // One recorder at a time: the others stop first, so they don't clear `isRecording` after.
        NotificationCenter.default.post(name: .shortcutRecorderStarted, object: action.rawValue)
        recording = true
        message = nil
        shortcuts.isRecording = true
        #if os(macOS)
        let window = NSApp.keyWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only keys typed in Settings: typing in a note meanwhile types as usual.
            guard window == nil || event.window === window else { return event }
            handle(KeyCombo(event: event))
            return nil
        }
        // Moving to another window ends recording.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { stopRecording() }
        }
        #endif
    }

    private func stopRecording() {
        guard recording else { return }
        recording = false
        shortcuts.isRecording = false
        #if os(macOS)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        #endif
    }

    private func handle(_ combo: KeyCombo?) {
        guard recording, let combo else { return }
        if combo.modifiers.isEmpty, combo.key == "escape" {
            stopRecording()
            return
        }
        if combo.modifiers.isEmpty, combo.key == "delete" || combo.key == "forwardDelete" {
            shortcuts.set(nil, for: action)
            stopRecording()
            return
        }
        // Only modifier keys so far: keep waiting for the key itself.
        if combo.key.isEmpty { return }
        switch shortcuts.problem(with: combo, for: action) {
        case .needsModifier:
            message = action.isGlobal ? "Use two of ⌘ ⌥ ⌃" : "Include ⌘, ⌥ or ⌃"
            return
        case .reserved:
            message = "\(combo.displayString) is reserved"
            return
        case nil:
            break
        }
        let displaced = shortcuts.set(combo, for: action)
        stopRecording()
        message = displaced.map { "Removed from “\($0.title)”" }
    }
}

#if os(iOS)
/// While active, holds keyboard focus and reports each hardware-keyboard press. SwiftUI's
/// `onKeyPress` doesn't reliably receive ⌘ combinations on iOS; UIKit's `pressesBegan` does.
private struct KeyCapture: UIViewRepresentable {
    var isActive: Bool
    var onKey: (KeyCombo) -> Void

    func makeUIView(context: Context) -> CaptureView {
        CaptureView()
    }

    func updateUIView(_ view: CaptureView, context: Context) {
        view.onKey = onKey
        if isActive, !view.isFirstResponder {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !isActive, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    final class CaptureView: UIView {
        var onKey: ((KeyCombo) -> Void)?

        override var canBecomeFirstResponder: Bool { true }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard let key = presses.first?.key else {
                super.pressesBegan(presses, with: event)
                return
            }
            if let combo = KeyCombo(uiKey: key) { onKey?(combo) }
        }
    }
}
#endif
