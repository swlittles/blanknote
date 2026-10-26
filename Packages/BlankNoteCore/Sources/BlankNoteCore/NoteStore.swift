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
        /// The notes folder: a profile's folder. Without one, the notes live directly in
        /// `NotesContainer` (iCloud Drive or Documents).
        public var root: URL?
        /// Where `root` is, which decides whether iCloud conflict handling and watching are used.
        public var rootLocation: Location = .local
        public var indexURL: URL?
        public var useICloud = true
        public var watchForChanges = true
        /// Created as the first note when the folder is empty on first launch.
        public var welcomeNote: String?

        public init(root: URL? = nil, rootLocation: Location = .local, indexURL: URL? = nil, useICloud: Bool = true,
                    watchForChanges: Bool = true, welcomeNote: String? = nil) {
            self.root = root
            self.rootLocation = rootLocation
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
    /// Bumped each time the search index finishes an update. Notes appear in `notes` before the index
    /// has them, so a search shown at that moment looks again when this changes.
    public private(set) var indexRevision = 0
    public var lastError: String?
    /// Things worth telling the user that happened without them doing anything. The app shows
    /// them and calls `clearNotices()`.
    public private(set) var notices: [Notice] = []

    public struct Notice: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// Two devices (or apps) edited the note at once; the other version was saved as a copy.
            case keptBothVersions(title: String)
            /// The open note was moved or deleted elsewhere while it had unsaved edits, so they
            /// were saved as a new note.
            case savedAsNewNote(title: String)
        }
        public let id = UUID()
        public var kind: Kind
    }

    public func clearNotices() {
        notices.removeAll()
    }

    public func post(_ kind: Notice.Kind) {
        notices.append(Notice(kind: kind))
    }

    @ObservationIgnored private let options: Options
    @ObservationIgnored private var fileSystem: NoteFileSystem?
    @ObservationIgnored private var index: SearchIndex?
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var scheduledReconcile: Task<Void, Never>?
    @ObservationIgnored private var reconciling = false
    @ObservationIgnored private var reconcileAgain = false
    @ObservationIgnored private var pendingFull = false
    /// Bumped when the folder moves, so a scan of the old place is thrown away.
    @ObservationIgnored private var rootGeneration = 0
    /// Notes and folders changed here while a scan runs: what's in memory for them is newer than
    /// what the scan saw.
    @ObservationIgnored private var changedPaths: Set<String> = []
    @ObservationIgnored private var foldersChanged = false
    /// Where notes and folders moved by this store went (old path → new path), so windows showing
    /// one that another window moved, renamed or trashed can follow it.
    @ObservationIgnored private var movedPaths: [String: String] = [:]
    @ObservationIgnored private var movedFolders: [String: String] = [:]

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
        let indexURL = options.indexURL ?? Self.defaultIndexURL
        do {
            index = try SearchIndex(url: indexURL, rootIdentity: root.standardizedFileURL.path)
        } catch {
            // A damaged cache: start a new one (notes load without an index if even that fails).
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: indexURL.path + suffix))
            }
            index = try? SearchIndex(url: indexURL, rootIdentity: root.standardizedFileURL.path)
        }

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

    /// Follows the notes folder to a new place (its profile was renamed). Note paths are relative,
    /// so open notes and selections stay valid.
    public func moveRoot(to root: URL) {
        guard root != rootURL else { return }
        rootURL = root
        fileSystem = NoteFileSystem(root: root)
        rootGeneration += 1
        if options.watchForChanges {
            watcher = FolderWatcher(root: root, iCloud: location == .iCloud) { [weak self] in
                Task { @MainActor in self?.scheduleReconcile() }
            }
        }
        scheduleReconcile()
    }

    nonisolated static var defaultIndexURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Index", isDirectory: true)
            .appendingPathComponent("notes.sqlite")
    }

    nonisolated static func resolveRoot(_ options: Options) -> (URL, Location) {
        if let root = options.root { return (root, options.rootLocation) }
        return NotesContainer.resolve(useICloud: options.useICloud)
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
        guard fileSystem != nil else { return }
        if reconciling {
            reconcileAgain = true
            if full { pendingFull = true }
            return
        }
        reconciling = true
        defer { reconciling = false }
        var forceFull = full
        repeat {
            reconcileAgain = false
            forceFull = forceFull || pendingFull
            pendingFull = false
            guard let fileSystem else { return }
            let startRoot = rootGeneration
            changedPaths = []
            foldersChanged = false
            let known = forceFull ? [:] : Dictionary(notes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            let resolveConflicts = location == .iCloud
            var outcome = await Task.detached(priority: .utility) {
                Self.scan(fileSystem, known: known, resolveConflicts: resolveConflicts)
            }.value
            guard startRoot == rootGeneration else {
                reconcileAgain = true
                continue
            }
            // Notes and folders changed here during the scan keep their newer state; the rest of
            // the scan still applies, so a busy folder doesn't keep a scan from ever finishing.
            let changed = changedPaths
            if !changed.isEmpty {
                outcome.notes = (outcome.notes.filter { !changed.contains($0.path) } + notes.filter { changed.contains($0.path) })
                    .sorted { $0.path < $1.path }
                outcome.upserts.removeAll { changed.contains($0.summary.path) }
                outcome.removals.removeAll { changed.contains($0) }
            }
            if foldersChanged { outcome.folders = folders }
            if outcome.notes != notes.sorted(by: { $0.path < $1.path }) { notes = outcome.notes }
            if outcome.folders != folders { folders = outcome.folders }
            if !outcome.conflicted.isEmpty {
                reconcileAgain = true
                notices += outcome.conflicted.map { path in
                    Notice(kind: .keptBothVersions(title: outcome.notes.first { $0.path == path }?.displayTitle ?? Self.baseName(path)))
                }
            }
            if let index {
                if forceFull { await index.removeAll() }
                await index.apply(upserts: outcome.upserts, removals: outcome.removals)
                // A rebuild may have emptied the index after notes saved meanwhile were indexed.
                if forceFull { await reindex(paths: changedPaths) }
                indexRevision += 1
            }
            forceFull = false
        } while reconcileAgain
    }

    struct ScanOutcome: Sendable {
        var notes: [NoteSummary] = []
        var folders: [String] = []
        var upserts: [(summary: NoteSummary, body: String)] = []
        var removals: [String] = []
        /// Notes that had a conflicting version saved as a copy.
        var conflicted: [String] = []
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
                outcome.conflicted.append(file.path)
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

    public func fileExists(_ path: String) -> Bool {
        fileSystem?.exists(path) ?? false
    }

    /// Where a note moved by this store is now (following renames, moves and Recently Deleted),
    /// or nil if it wasn't moved here.
    public func currentPath(for path: String) -> String? {
        var current = path
        var steps = 0
        while let next = movedPaths[current], next != current, steps < 64 {
            current = next
            steps += 1
        }
        return current == path ? nil : current
    }

    /// Where a folder renamed by this store is now, or nil if it wasn't renamed here.
    public func currentFolder(for path: String) -> String? {
        var current = path
        var steps = 0
        while steps < 64 {
            if let next = movedFolders[current], next != current {
                current = next
            } else if let parent = movedFolders.keys.first(where: { current.hasPrefix($0 + "/") }), let next = movedFolders[parent] {
                current = next + current.dropFirst(parent.count)
            } else {
                break
            }
            steps += 1
        }
        return current == path ? nil : current
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
        let file = Self.merging(body, into: NoteFile(body: ""))
        let title = NoteText.title(of: file.body)
        let path = fileSystem.uniquePath(in: folder, name: title.isEmpty ? "Untitled" : NoteText.fileName(for: title))
        try write(file, to: path, replacing: nil)
        return path
    }

    /// Saves a new body (keeping the front matter) and renames the file to follow the title.
    /// Returns the note's path, which changes when the file was renamed.
    ///
    /// `base` is the text the editor started from. If the file's text has changed since (another
    /// app or device saved it), that version is kept as a "conflicted copy" note before it's replaced.
    @discardableResult
    public func saveNote(_ path: String, body: String, base: String? = nil) throws -> String {
        let fileSystem = try requireFileSystem()
        let disk = try? readNote(path)
        if let base, let disk, disk.body != Self.merging(base, into: disk).body, disk.body != Self.merging(body, into: disk).body {
            let copy = fileSystem.uniquePath(in: (path as NSString).deletingLastPathComponent,
                                             name: "\(Self.baseName(path)) (conflicted copy)", extension: Self.fileExtension(path))
            try write(disk, to: copy, replacing: nil)
            let title = NoteText.title(of: disk.body)
            post(.keptBothVersions(title: title.isEmpty ? Self.baseName(path) : title))
        }
        let file = Self.merging(body, into: disk ?? NoteFile(body: ""))
        var target = path
        if !Self.isTrashed(path) {
            let title = NoteText.title(of: file.body)
            let name = title.isEmpty ? "Untitled" : NoteText.fileName(for: title)
            let folder = (path as NSString).deletingLastPathComponent
            let ext = (path as NSString).pathExtension
            target = fileSystem.uniquePath(in: folder, name: name, extension: ext.isEmpty ? "md" : ext, current: path)
        }
        if target != path { try fileSystem.move(path, to: target) }
        try write(file, to: target, replacing: path)
        return target
    }

    /// The note with `body` as its text. A body that starts with front matter of its own (say a
    /// whole note pasted from Obsidian) supplies the file's front matter, rather than being saved
    /// under the existing front matter, where it would pile up again on every save.
    static func merging(_ body: String, into file: NoteFile) -> NoteFile {
        var file = file
        let typed = NoteFile(contents: body)
        guard !typed.frontMatter.isEmpty else {
            file.body = body
            return file
        }
        let typedKeys = Set(typed.frontMatter.entries.map(\.key).filter { !$0.isEmpty })
        file.frontMatter.entries = typed.frontMatter.entries + file.frontMatter.entries.filter { !$0.key.isEmpty && !typedKeys.contains($0.key) }
        file.body = typed.body
        return file
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
        // Only the path changed: no need to rewrite the file.
        record(try readNote(target), at: target, replacing: path, modified: fileSystem.modificationDate(target) ?? Date())
        if !folder.isEmpty, !folders.contains(folder) { addFolder(folder) }
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
        if !folder.isEmpty, !folders.contains(folder) { addFolder(folder) }
        return target
    }

    public func deleteNotePermanently(_ path: String) throws {
        try requireFileSystem().remove(path)
        changedPaths.insert(path)
        notes.removeAll { $0.path == path }
        let index = self.index
        Task {
            await index?.apply(upserts: [], removals: [path])
            indexRevision += 1
        }
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
        addFolder(path)
        return path
    }

    private func addFolder(_ path: String) {
        foldersChanged = true
        var added = [path]
        // Its parents too, for a folder made inside one that doesn't exist yet.
        var parent = (path as NSString).deletingLastPathComponent
        while !parent.isEmpty, !folders.contains(parent) {
            added.append(parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
        folders = (folders + added.filter { !folders.contains($0) }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Renames a folder and returns its new path.
    @discardableResult
    public func renameFolder(_ path: String, to name: String) async throws -> String {
        let fileSystem = try requireFileSystem()
        let parent = (path as NSString).deletingLastPathComponent
        let cleanName = NoteText.fileName(for: name)
        guard cleanName != (path as NSString).lastPathComponent else { return path }
        let caseOnly = parent.isEmpty ? cleanName : "\(parent)/\(cleanName)"
        let target = cleanName.lowercased() == (path as NSString).lastPathComponent.lowercased() && !NoteFileSystem.isHiddenFolder(caseOnly)
            ? caseOnly
            : uniqueFolderPath(named: name, in: parent, fileSystem: fileSystem)
        try fileSystem.move(path, to: target)

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
        for item in renamed {
            changedPaths.formUnion([item.old, item.new])
            noteMoved(item.old, to: item.new)
        }
        foldersChanged = true
        movedFolders[path] = target
        movedFolders[target] = nil
        folders = folders.map { moved($0) ?? $0 }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        // Notes deleted from the folder go back to its new name when restored.
        for note in notes where note.isTrashed {
            guard var file = try? readNote(note.path), let from = file.frontMatter.value("trashed-from"),
                  let newFrom = moved(from) else { continue }
            file.frontMatter.set("trashed-from", FrontMatter.quoteIfNeeded(newFrom))
            try? write(file, to: note.path, replacing: note.path)
        }
        await reindex(renamed)
        return target
    }

    /// Moves the folder's notes (including subfolders') to Recently Deleted and removes the folder.
    /// Returns the notes' paths in Recently Deleted.
    @discardableResult
    public func deleteFolder(_ path: String) throws -> [String] {
        let fileSystem = try requireFileSystem()
        var trashed: [String] = []
        for note in notes where note.path.hasPrefix(path + "/") {
            trashed.append(try trashNote(note.path))
        }
        if fileSystem.containsFiles(path) {
            // Files BlankNote doesn't show (images, notes still downloading from iCloud…) aren't
            // erased: the folder with what's left goes in the Recently Deleted folder.
            let name = (path as NSString).lastPathComponent
            try fileSystem.move(path, to: uniqueFolderPath(named: "\(name) (deleted folder)", in: NoteFileSystem.trashFolder, fileSystem: fileSystem))
        } else {
            try fileSystem.remove(path)
        }
        foldersChanged = true
        folders.removeAll { $0 == path || $0.hasPrefix(path + "/") }
        return trashed
    }

    private func uniqueFolderPath(named name: String, in parent: String, fileSystem: NoteFileSystem) -> String {
        let base = NoteText.fileName(for: name.isEmpty ? "New Folder" : name)
        var number = 1
        while true {
            let folderName = number == 1 ? base : "\(base) \(number)"
            let path = parent.isEmpty ? folderName : "\(parent)/\(folderName)"
            if !fileSystem.exists(path), parent == NoteFileSystem.trashFolder || !NoteFileSystem.isHiddenFolder(path) { return path }
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
        record(file, at: path, replacing: oldPath, modified: modified)
    }

    /// Updates the in-memory summary and the index for a note now at `path`.
    private func record(_ file: NoteFile, at path: String, replacing oldPath: String?, modified: Date) {
        let created = summary(for: oldPath ?? path)?.created ?? modified
        let summary = NoteSummary(path: path, file: file, created: created, modified: modified)
        changedPaths.insert(path)
        movedPaths[path] = nil
        if let oldPath, oldPath != path {
            changedPaths.insert(oldPath)
            noteMoved(oldPath, to: path)
        }
        notes.removeAll { $0.path == path || $0.path == oldPath }
        notes.append(summary)
        let removals = oldPath.flatMap { $0 == path ? nil : [$0] } ?? []
        let index = self.index
        Task {
            await index?.apply(upserts: [(summary, file.body)], removals: removals)
            indexRevision += 1
        }
    }

    private func noteMoved(_ oldPath: String, to newPath: String) {
        if movedPaths.count > 500 { movedPaths.removeAll() }
        movedPaths[oldPath] = newPath
        // Whatever is at the new path now is this note, not one that once moved away from there.
        movedPaths[newPath] = nil
    }

    /// Re-reads these notes into the index.
    private func reindex(paths: Set<String>) async {
        await reindex(paths.filter { summary(for: $0) != nil }.map { (old: $0, new: $0) }, removingOld: false)
    }

    private func reindex(_ renamed: [(old: String, new: String)], removingOld: Bool = true) async {
        guard let fileSystem, let index, !renamed.isEmpty else { return }
        let notes = renamed.compactMap { item in summary(for: item.new) }
        let upserts = await Task.detached(priority: .utility) {
            notes.compactMap { note -> (summary: NoteSummary, body: String)? in
                guard let text = try? fileSystem.read(note.path) else { return nil }
                return (note, NoteFile(contents: text).body)
            }
        }.value
        await index.apply(upserts: upserts, removals: removingOld ? renamed.map(\.old) : [])
        indexRevision += 1
    }

    public static func isTrashed(_ path: String) -> Bool {
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
