import Foundation
import Observation

/// The notes folder as the app sees it: every note's summary, the folder list, and the operations
/// that change them. Files on disk are the source of truth; this mirrors them and keeps the search
/// index in step.
@MainActor @Observable
public final class NoteStore {
    public enum Location: Sendable, Equatable {
        case iCloud
        case local
    }

    public struct Options: Sendable {
        /// Use this folder instead of iCloud Drive or Documents (tests, demo data).
        public var root: URL?
        public var indexURL: URL?
        public var useICloud = true
        public var watchForChanges = true
        /// Created as the first note when the folder is empty on first launch.
        public var welcomeNote: String?

        public init(root: URL? = nil, indexURL: URL? = nil, useICloud: Bool = true, watchForChanges: Bool = true, welcomeNote: String? = nil) {
            self.root = root
            self.indexURL = indexURL
            self.useICloud = useICloud
            self.watchForChanges = watchForChanges
            self.welcomeNote = welcomeNote
        }
    }

    public enum StoreError: LocalizedError {
        case notReady
        public var errorDescription: String? { "The notes folder isn't available yet." }
    }

    /// Notes are kept in Recently Deleted this long.
    public static let trashRetention: TimeInterval = 30 * 24 * 3600

    public private(set) var notes: [NoteSummary] = []
    public private(set) var folders: [String] = []
    public private(set) var location: Location = .local
    public private(set) var rootURL: URL?
    public private(set) var isReady = false
    public var lastError: String?

    @ObservationIgnored private let options: Options
    @ObservationIgnored private var fileSystem: NoteFileSystem?
    @ObservationIgnored private var index: SearchIndex?
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var scheduledReconcile: Task<Void, Never>?
    @ObservationIgnored private var reconciling = false
    @ObservationIgnored private var reconcileAgain = false
    /// Bumped by every change made here, so a folder scan that started before it is thrown away
    /// instead of overwriting newer state.
    @ObservationIgnored private var generation = 0

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: Loading

    public func start() async {
        if let startTask {
            await startTask.value
            return
        }
        let task = Task { await load() }
        startTask = task
        await task.value
    }

    private func load() async {
        let options = self.options
        let (root, location) = await Task.detached(priority: .userInitiated) { Self.resolveRoot(options) }.value
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        rootURL = root
        self.location = location
        fileSystem = NoteFileSystem(root: root)
        index = try? SearchIndex(url: options.indexURL ?? Self.defaultIndexURL, rootIdentity: root.standardizedFileURL.path)

        if let cached = await index?.allSummaries(), !cached.isEmpty {
            notes = cached
            isReady = true
        }
        await reconcile()

        let seededKey = "seededWelcomeNote"
        if let welcome = options.welcomeNote, notes.isEmpty, !UserDefaults.standard.bool(forKey: seededKey) {
            UserDefaults.standard.set(true, forKey: seededKey)
            _ = try? createNote(in: "", body: welcome)
        }
        isReady = true
        purgeExpiredTrash()

        if options.watchForChanges {
            watcher = FolderWatcher(root: root, iCloud: location == .iCloud) { [weak self] in
                Task { @MainActor in self?.scheduleReconcile() }
            }
        }
    }

    nonisolated static var defaultIndexURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Index", isDirectory: true)
            .appendingPathComponent("notes.sqlite")
    }

    /// iCloud Drive when the app has a container and the user is signed in; Documents otherwise.
    /// Notes written locally before iCloud became available are moved into iCloud.
    nonisolated static func resolveRoot(_ options: Options) -> (URL, Location) {
        if let root = options.root { return (root, .local) }
        let local = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if options.useICloud, let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            let documents = container.appendingPathComponent("Documents", isDirectory: true)
            try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            moveLocalNotes(from: local, intoICloud: documents)
            return (documents, .iCloud)
        }
        return (local, .local)
    }

    nonisolated private static func moveLocalNotes(from local: URL, intoICloud documents: URL) {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) else { return }
        for item in items where !item.lastPathComponent.hasPrefix(".") || item.lastPathComponent == NoteFileSystem.trashFolder {
            var target = documents.appendingPathComponent(item.lastPathComponent)
            var number = 2
            while manager.fileExists(atPath: target.path) {
                let base = item.deletingPathExtension().lastPathComponent
                let ext = item.pathExtension
                target = documents.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
                number += 1
            }
            try? manager.setUbiquitous(true, itemAt: item, destinationURL: target)
        }
    }

    /// Re-scans the folder soon, coalescing bursts of change notifications.
    public func scheduleReconcile() {
        scheduledReconcile?.cancel()
        scheduledReconcile = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.reconcile()
        }
    }

    /// Brings `notes`, `folders` and the index in line with the files, re-reading only files whose
    /// modification date changed. `full` re-reads everything (rebuilding the index).
    public func reconcile(full: Bool = false) async {
        guard let fileSystem, let index else { return }
        if reconciling {
            reconcileAgain = true
            return
        }
        reconciling = true
        defer { reconciling = false }
        var forceFull = full
        repeat {
            reconcileAgain = false
            let startGeneration = generation
            let known = forceFull ? [:] : Dictionary(notes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            let resolveConflicts = location == .iCloud
            let outcome = await Task.detached(priority: .utility) {
                Self.scan(fileSystem, known: known, resolveConflicts: resolveConflicts)
            }.value
            guard startGeneration == generation else {
                reconcileAgain = true
                continue
            }
            if forceFull { await index.removeAll() }
            await index.apply(upserts: outcome.upserts, removals: outcome.removals)
            if outcome.notes != notes.sorted(by: { $0.path < $1.path }) { notes = outcome.notes }
            if outcome.folders != folders { folders = outcome.folders }
            if outcome.createdConflictCopies { reconcileAgain = true }
            forceFull = false
        } while reconcileAgain
    }

    struct ScanOutcome: Sendable {
        var notes: [NoteSummary] = []
        var folders: [String] = []
        var upserts: [(summary: NoteSummary, body: String)] = []
        var removals: [String] = []
        var createdConflictCopies = false
    }

    nonisolated static func scan(_ fileSystem: NoteFileSystem, known: [String: NoteSummary], resolveConflicts: Bool) -> ScanOutcome {
        let result = fileSystem.scan()
        for placeholder in result.placeholders {
            try? FileManager.default.startDownloadingUbiquitousItem(at: placeholder)
        }
        var outcome = ScanOutcome(folders: result.folders)
        var seen = Set<String>()
        for file in result.files {
            seen.insert(file.path)
            if let cached = known[file.path], abs(cached.modified.timeIntervalSince(file.modified)) < 0.0005 {
                outcome.notes.append(cached)
                continue
            }
            if resolveConflicts, !fileSystem.resolveConflicts(at: file.path).isEmpty {
                outcome.createdConflictCopies = true
            }
            guard let text = try? fileSystem.read(file.path) else { continue }
            let note = NoteFile(contents: text)
            let summary = NoteSummary(path: file.path, file: note, created: file.created, modified: file.modified)
            outcome.notes.append(summary)
            outcome.upserts.append((summary, note.body))
        }
        outcome.removals = known.keys.filter { !seen.contains($0) }
        outcome.notes.sort { $0.path < $1.path }
        return outcome
    }

    // MARK: Reading

    public func summary(for path: String) -> NoteSummary? {
        notes.first { $0.path == path }
    }

    public func readNote(_ path: String) throws -> NoteFile {
        NoteFile(contents: try requireFileSystem().read(path))
    }

    public func search(_ text: String) async -> [String] {
        await index?.search(text) ?? []
    }

    /// Every tag in use outside Recently Deleted, sorted, with how many notes carry it.
    public var tagCounts: [(tag: String, count: Int)] {
        var counts: [String: (tag: String, count: Int)] = [:]
        for note in notes where !note.isTrashed {
            for tag in note.tags {
                counts[tag.lowercased(), default: (tag, 0)].count += 1
            }
        }
        return counts.values.sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
    }

    public func report(_ error: Error) {
        lastError = error.localizedDescription
    }

    // MARK: Notes

    @discardableResult
    public func createNote(in folder: String, body: String = "") throws -> String {
        let fileSystem = try requireFileSystem()
        let title = NoteText.title(of: body)
        let path = fileSystem.uniquePath(in: folder, name: title.isEmpty ? "Untitled" : NoteText.fileName(for: title))
        try write(NoteFile(body: body), to: path, replacing: nil)
        return path
    }

    /// Saves a new body (keeping the front matter) and renames the file to follow the title.
    /// Returns the note's path, which changes when the file was renamed.
    @discardableResult
    public func saveNote(_ path: String, body: String) throws -> String {
        let fileSystem = try requireFileSystem()
        var file = (try? readNote(path)) ?? NoteFile(body: "")
        file.body = body
        var target = path
        if !Self.isTrashed(path) {
            let title = NoteText.title(of: body)
            let name = title.isEmpty ? "Untitled" : NoteText.fileName(for: title)
            let folder = (path as NSString).deletingLastPathComponent
            let ext = (path as NSString).pathExtension
            target = fileSystem.uniquePath(in: folder, name: name, extension: ext.isEmpty ? "md" : ext, current: path)
        }
        if target != path { try fileSystem.move(path, to: target) }
        try write(file, to: target, replacing: path)
        return target
    }

    public func setPinned(_ pinned: Bool, for path: String) throws {
        var file = try readNote(path)
        file.frontMatter.set("pinned", pinned ? "true" : nil)
        try write(file, to: path, replacing: path)
    }

    /// Moves a note into `folder` (`""` is the top level) and returns its new path.
    @discardableResult
    public func moveNote(_ path: String, to folder: String) throws -> String {
        let fileSystem = try requireFileSystem()
        guard (path as NSString).deletingLastPathComponent != folder else { return path }
        let target = fileSystem.uniquePath(in: folder, name: Self.baseName(path), extension: Self.fileExtension(path))
        try fileSystem.move(path, to: target)
        try write(try readNote(target), to: target, replacing: path)
        return target
    }

    /// Moves a note to Recently Deleted, remembering where it came from. Returns its new path.
    @discardableResult
    public func trashNote(_ path: String) throws -> String {
        let fileSystem = try requireFileSystem()
        guard !Self.isTrashed(path) else { return path }
        var file = try readNote(path)
        let folder = (path as NSString).deletingLastPathComponent
        file.frontMatter.set("trashed-from", folder.isEmpty ? nil : FrontMatter.quoteIfNeeded(folder))
        file.frontMatter.set("trashed", ISO8601DateFormatter().string(from: Date()))
        let target = fileSystem.uniquePath(in: NoteFileSystem.trashFolder, name: Self.baseName(path), extension: Self.fileExtension(path))
        try fileSystem.move(path, to: target)
        try write(file, to: target, replacing: path)
        return target
    }

    /// Puts a note from Recently Deleted back in its folder. Returns its new path.
    @discardableResult
    public func restoreNote(_ path: String) throws -> String {
        let fileSystem = try requireFileSystem()
        guard Self.isTrashed(path) else { return path }
        var file = try readNote(path)
        let folder = file.frontMatter.value("trashed-from") ?? ""
        file.frontMatter.set("trashed-from", nil)
        file.frontMatter.set("trashed", nil)
        let target = fileSystem.uniquePath(in: folder, name: Self.baseName(path), extension: Self.fileExtension(path))
        try fileSystem.move(path, to: target)
        try write(file, to: target, replacing: path)
        if !folder.isEmpty, !folders.contains(folder) {
            folders = (folders + [folder]).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        return target
    }

    public func deleteNotePermanently(_ path: String) throws {
        try requireFileSystem().remove(path)
        generation += 1
        notes.removeAll { $0.path == path }
        let index = self.index
        Task { await index?.apply(upserts: [], removals: [path]) }
    }

    public func emptyTrash() throws {
        for note in notes where note.isTrashed {
            try deleteNotePermanently(note.path)
        }
    }

    private func purgeExpiredTrash() {
        let formatter = ISO8601DateFormatter()
        for note in notes where note.isTrashed {
            guard let stamp = (try? readNote(note.path))?.frontMatter.value("trashed"),
                  let trashed = formatter.date(from: stamp),
                  Date().timeIntervalSince(trashed) > Self.trashRetention else { continue }
            try? deleteNotePermanently(note.path)
        }
    }

    // MARK: Folders

    /// Creates a folder and returns its path.
    @discardableResult
    public func createFolder(named name: String, in parent: String = "") throws -> String {
        let fileSystem = try requireFileSystem()
        let path = uniqueFolderPath(named: name, in: parent, fileSystem: fileSystem)
        try fileSystem.createFolder(path)
        generation += 1
        folders = (folders + [path]).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return path
    }

    /// Renames a folder and returns its new path.
    @discardableResult
    public func renameFolder(_ path: String, to name: String) async throws -> String {
        let fileSystem = try requireFileSystem()
        let parent = (path as NSString).deletingLastPathComponent
        let cleanName = NoteText.fileName(for: name)
        guard cleanName != (path as NSString).lastPathComponent else { return path }
        let target = cleanName.lowercased() == (path as NSString).lastPathComponent.lowercased()
            ? (parent.isEmpty ? cleanName : "\(parent)/\(cleanName)")
            : uniqueFolderPath(named: name, in: parent, fileSystem: fileSystem)
        try fileSystem.move(path, to: target)
        generation += 1

        func moved(_ itemPath: String) -> String? {
            guard itemPath == path || itemPath.hasPrefix(path + "/") else { return nil }
            return target + itemPath.dropFirst(path.count)
        }
        var renamed: [(old: String, new: String)] = []
        notes = notes.map { note in
            guard let newPath = moved(note.path) else { return note }
            renamed.append((note.path, newPath))
            var note = note
            note.path = newPath
            return note
        }
        folders = folders.map { moved($0) ?? $0 }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        await reindex(renamed)
        return target
    }

    /// Moves the folder's notes (including subfolders') to Recently Deleted and removes the folder.
    public func deleteFolder(_ path: String) throws {
        for note in notes where note.path.hasPrefix(path + "/") {
            try trashNote(note.path)
        }
        try requireFileSystem().remove(path)
        generation += 1
        folders.removeAll { $0 == path || $0.hasPrefix(path + "/") }
    }

    private func uniqueFolderPath(named name: String, in parent: String, fileSystem: NoteFileSystem) -> String {
        let base = NoteText.fileName(for: name.isEmpty ? "New Folder" : name)
        var number = 1
        while true {
            let folderName = number == 1 ? base : "\(base) \(number)"
            let path = parent.isEmpty ? folderName : "\(parent)/\(folderName)"
            if !fileSystem.exists(path) { return path }
            number += 1
        }
    }

    // MARK: Helpers

    private func requireFileSystem() throws -> NoteFileSystem {
        guard let fileSystem else { throw StoreError.notReady }
        return fileSystem
    }

    /// Writes a note and updates the in-memory summary and the index to match.
    private func write(_ file: NoteFile, to path: String, replacing oldPath: String?) throws {
        let modified = try requireFileSystem().write(file.contents, to: path)
        let created = summary(for: oldPath ?? path)?.created ?? modified
        let summary = NoteSummary(path: path, file: file, created: created, modified: modified)
        generation += 1
        notes.removeAll { $0.path == path || $0.path == oldPath }
        notes.append(summary)
        let removals = oldPath.flatMap { $0 == path ? nil : [$0] } ?? []
        let index = self.index
        Task { await index?.apply(upserts: [(summary, file.body)], removals: removals) }
    }

    private func reindex(_ renamed: [(old: String, new: String)]) async {
        guard let fileSystem, let index, !renamed.isEmpty else { return }
        let notes = renamed.compactMap { item in summary(for: item.new) }
        let upserts = await Task.detached(priority: .utility) {
            notes.compactMap { note -> (summary: NoteSummary, body: String)? in
                guard let text = try? fileSystem.read(note.path) else { return nil }
                return (note, NoteFile(contents: text).body)
            }
        }.value
        await index.apply(upserts: upserts, removals: renamed.map(\.old))
    }

    static func isTrashed(_ path: String) -> Bool {
        path.hasPrefix(NoteFileSystem.trashFolder + "/")
    }

    static func baseName(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    static func fileExtension(_ path: String) -> String {
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? "md" : ext
    }
}
