import Foundation
import BlankNoteCore

/// Launch arguments for screenshots and manual testing:
///
/// - `-demo`: use fresh sample profiles and notes instead of your real ones
/// - `-profile "<name>"`: switch to this profile at launch
/// - `-open "<title>"`: open the note with this title
/// - `-sidebar all|trash|folder:<path>|tag:<tag>`
/// - `-search "<text>"`
/// - `-theme system|light|dark`: the theme to start with; Settings can still change it
/// - `-resetShortcuts`: start with the default keyboard shortcuts
/// - `-settings general|profiles` (iPhone, iPad): open Settings; `-newProfile`: the New Profile sheet
enum LaunchOptions {
    private static let arguments = ProcessInfo.processInfo.arguments

    static var isDemo: Bool { arguments.contains("-demo") }

    static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Saves the `-theme` argument as the theme setting, as if it had been picked in Settings.
    static func applyTheme() {
        guard let value = value(after: "-theme"), let theme = Appearance(rawValue: value) else { return }
        UserDefaults.standard.set(theme.rawValue, forKey: Appearance.storageKey)
    }


    @MainActor
    static func makeShortcutStore() -> ShortcutStore {
        if arguments.contains("-resetShortcuts") {
            UserDefaults.standard.removeObject(forKey: ShortcutStore.defaultsKey)
        }
        return ShortcutStore()
    }

    static var settingsRoute: SettingsRoute? { value(after: "-settings").flatMap(SettingsRoute.init(rawValue:)) }
    static var showNewProfile: Bool { arguments.contains("-newProfile") }

    static var openTitle: String? { value(after: "-open") }
    static var search: String? { value(after: "-search") }

    static var sidebar: SidebarItem? {
        guard let value = value(after: "-sidebar") else { return nil }
        if value == "all" { return .all }
        if value == "trash" { return .trash }
        if value.hasPrefix("folder:") { return .folder(String(value.dropFirst(7))) }
        if value.hasPrefix("tag:") { return .tag(String(value.dropFirst(4))) }
        return nil
    }

    static var profileName: String? { value(after: "-profile") }

    private static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// Where each profile's search index goes (one file per profile).
    static var indexFolder: URL {
        caches.appendingPathComponent(isDemo ? "Demo Index" : "Index", isDirectory: true)
    }

    /// The profiles: the real ones, or with `-demo` a fresh set of sample profiles.
    @MainActor
    static func makeProfileStore() -> ProfileStore {
        guard isDemo else { return ProfileStore() }
        let root = caches.appendingPathComponent("Demo Notes", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: indexFolder)
        SampleNotes.write(to: root)
        return ProfileStore(container: root)
    }
}
