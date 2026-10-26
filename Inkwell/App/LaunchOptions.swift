import Foundation
import InkwellCore

/// Launch arguments for screenshots and manual testing:
///
/// - `-demo`: use a fresh folder of sample notes instead of your real ones
/// - `-open "<title>"`: open the note with this title
/// - `-sidebar all|trash|folder:<path>|tag:<tag>`
/// - `-search "<text>"`
/// - `-appearance light|dark` (any `@AppStorage` key can be set this way)
enum LaunchOptions {
    private static let arguments = ProcessInfo.processInfo.arguments

    static var isDemo: Bool { arguments.contains("-demo") }

    static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

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

    static var storeOptions: NoteStore.Options {
        guard isDemo else { return NoteStore.Options(welcomeNote: SampleNotes.welcome) }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let root = caches.appendingPathComponent("Demo Notes", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        SampleNotes.write(to: root)
        return NoteStore.Options(root: root, indexURL: caches.appendingPathComponent("Demo Index/notes.sqlite"), useICloud: false)
    }
}
