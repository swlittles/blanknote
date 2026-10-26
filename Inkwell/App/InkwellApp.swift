import InkwellCore
import SwiftUI

@main
struct InkwellApp: App {
    @State private var app = AppModel(profiles: LaunchOptions.makeProfileStore())
    @State private var shortcuts = LaunchOptions.makeShortcutStore()
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.defaultValue

    init() {
        LaunchOptions.applyTheme()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            Group {
                if let store = app.store {
                    // A new profile means new notes: each window starts afresh.
                    RootView(store: store)
                        .id(app.storeID)
                } else {
                    Color(Palette.background).ignoresSafeArea()
                }
            }
            .task { await app.start() }
            .environment(app)
            .environment(shortcuts)
            // Also on every new window (iPad scenes start with the system style).
            .onAppear { appearance.apply() }
            .onChange(of: appearance) { appearance.apply() }
        }
        .commands {
            InkwellCommands(bindings: shortcuts.activeBindings, profiles: app.profiles.profiles,
                            activeProfileID: app.activeProfile?.id, app: app)
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        #endif

        #if os(macOS)
        Settings {
            ThemeTinted {
                TabView {
                    Tab("General", systemImage: "gearshape") {
                        if let store = app.store { SettingsView(store: store) }
                    }
                    Tab("Profiles", systemImage: "person.2") {
                        NavigationStack { ProfilesSettingsView() }
                            .frame(width: 560, height: 560)
                    }
                    Tab("Shortcuts", systemImage: "keyboard") {
                        ShortcutsSettingsView()
                            .frame(width: 560, height: 620)
                    }
                }
            }
            .environment(app)
            .environment(shortcuts)
        }
        #endif
    }
}

extension FocusedValues {
    @Entry var navigator: Navigator?
}

/// The menus (and, on iPad, the keyboard shortcut overlay). The shortcuts come from the
/// `ShortcutStore` as a value, so changing one in Settings rebuilds the menus straight away.
struct InkwellCommands: Commands {
    let bindings: [ShortcutAction: KeyCombo]
    /// Passed as values for the same reason as `bindings`.
    let profiles: [Profile]
    let activeProfileID: UUID?
    let app: AppModel
    @FocusedValue(\.navigator) private var focusedNavigator

    /// The focused window, or else the last active one (the Mac's Settings window is in front, or
    /// SwiftUI hasn't reported focus yet).
    private var navigator: Navigator? { focusedNavigator ?? ActionRouter.shared.activeNavigator }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            item(.newNote) { $0.newNote() }
            item(.newFolder) { $0.newFolderParent = "" }
        }
        CommandMenu("Note") {
            item(.searchNotes) { $0.requestSearch() }
            Divider()
            item(.togglePin, title: navigator?.openNote?.pinned == true ? "Unpin Note" : "Pin Note") { $0.togglePinOpenNote() }
            item(.copyMarkdown) { $0.copyOpenNote() }
            #if os(macOS)
            item(.showInFinder) { $0.showOpenNoteInFinder() }
            #endif
            Divider()
            item(.nextNote) { $0.selectAdjacent(1) }
            item(.previousNote) { $0.selectAdjacent(-1) }
            Divider()
            item(.deleteNote) { $0.deleteOpenNote() }
        }
        CommandMenu("Profile") {
            ForEach(profiles) { profile in
                Toggle(profile.name, isOn: Binding(get: { profile.id == activeProfileID }, set: { _ in app.switchTo(profile.id) }))
            }
            Divider()
            item(.nextProfile) { _ in app.switchToNeighbor(1) }
            item(.previousProfile) { _ in app.switchToNeighbor(-1) }
            Divider()
            Button("New Profile…") { navigator?.showNewProfile = true }
            #if os(macOS)
            SettingsLink { Text("Manage Profiles…") }
            #else
            Button("Manage Profiles…") { navigator?.settingsRoute = .profiles }
            #endif
        }
        CommandGroup(after: .sidebar) {
            Divider()
            item(.biggerText) { nav in
                nav.toasts.show("Text size \(Int(AppSettings.changeFontSize(by: 1))) pt", systemImage: "textformat.size.larger")
            }
            item(.smallerText) { nav in
                nav.toasts.show("Text size \(Int(AppSettings.changeFontSize(by: -1))) pt", systemImage: "textformat.size.smaller")
            }
            item(.actualSize) { nav in
                nav.toasts.show("Text size \(Int(AppSettings.changeFontSize(by: nil))) pt", systemImage: "textformat.size")
            }
            item(.toggleTheme) { nav in
                let theme = AppSettings.toggleTheme()
                nav.toasts.show(theme == .dark ? "Dark theme" : "Light theme", systemImage: theme == .dark ? "moon.fill" : "sun.max.fill")
            }
        }
        CommandMenu("Format") {
            ForEach(Self.formatSections, id: \.self) { section in
                Section {
                    ForEach(section, id: \.self) { action in
                        item(action) { _ in
                            if let format = action.formatAction { FormatCommand.send(format) }
                        }
                    }
                }
            }
        }
    }

    private static let formatSections: [[ShortcutAction]] = [
        [.bold, .italic, .strikethrough, .inlineCode, .link],
        [.heading, .checklist, .bulletList, .numberedList, .quote, .codeBlock],
        [.indent, .outdent],
    ]

    private func item(_ action: ShortcutAction, title: String? = nil, perform: @escaping (Navigator) -> Void) -> some View {
        // Never disabled: menus are built before the first window reports in, and SwiftUI wouldn't
        // rebuild them when it does. The window is looked up when the command runs instead.
        Button(title ?? action.title) {
            if let navigator { perform(navigator) }
        }
        .keyboardShortcut(bindings[action]?.keyboardShortcut)
    }
}
