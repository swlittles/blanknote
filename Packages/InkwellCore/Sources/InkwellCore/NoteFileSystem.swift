import Foundation

/// File access for the notes folder. Every path is relative to `root`.
///
/// All reads and writes go through `NSFileCoordinator`, which iCloud Drive requires so that the
/// sync daemon never sees a half-written file. It costs almost nothing for local folders.
public struct NoteFileSystem: Sendable {
    /// Hidden folder holding Recently Deleted notes. It syncs like everything else.
    public static let trashFolder = ".trash"
    /// Images and other files pasted into notes.
    public static let attachmentsFolder = "attachments"
    public static let noteExtensions: Set<String> = ["md", "markdown"]

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func url(for path: String) -> URL {
        path.isEmpty ? root : root.appendingPathComponent(path)
    }

    public func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: path).path)
    }

    // MARK: Scanning

    public struct ScanResult: Sendable {
        public struct File: Sendable {
            public var path: String
            public var created: Date
            public var modified: Date
        }
        public var files: [File] = []
        public var folders: [String] = []
        /// iCloud placeholders (`.Name.md.icloud`) for notes that haven't downloaded yet.
        public var placeholders: [URL] = []
    }

    public func scan() -> ScanResult {
        var result = ScanResult()
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return result }
        while let path = enumerator.nextObject() as? String {
            let name = (path as NSString).lastPathComponent
            let attributes = enumerator.fileAttributes ?? [:]
            let isDirectory = attributes[.type] as? FileAttributeType == .typeDirectory
            let inTrash = path.hasPrefix(Self.trashFolder + "/")

            if isDirectory {
                if path == Self.trashFolder { continue }
                if name.hasPrefix(".") || path == Self.attachmentsFolder || inTrash || name.hasSuffix(".app") {
                    enumerator.skipDescendants()
                    continue
                }
                result.folders.append(path)
                continue
            }
            if name.hasPrefix(".") {
                if name.hasSuffix(".icloud") { result.placeholders.append(url(for: path)) }
                continue
            }
            guard Self.noteExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            let modified = attributes[.modificationDate] as? Date ?? .distantPast
            result.files.append(.init(path: path, created: attributes[.creationDate] as? Date ?? modified, modified: modified))
        }
        result.folders.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return result
    }

    // MARK: Reading and writing

    public func read(_ path: String) throws -> String {
        var text = ""
        try coordinate(reading: url(for: path)) { url in
            let data = try Data(contentsOf: url)
            text = String(decoding: data, as: UTF8.self)
        }
        return text
    }

    /// Writes the file (creating its folder if needed) and returns its new modification date.
    @discardableResult
    public func write(_ contents: String, to path: String) throws -> Date {
        let target = url(for: path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try coordinate(writing: target, options: .forReplacing) { url in
            try Data(contents.utf8).write(to: url, options: .atomic)
        }
        return modificationDate(path) ?? Date()
    }

    public func modificationDate(_ path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url(for: path).path)[.modificationDate] as? Date
    }

    public func move(_ from: String, to destination: String) throws {
        guard from != destination else { return }
        let source = url(for: from)
        let target = url(for: destination)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        var coordinatorError: NSError?
        var moveError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: target, options: .forReplacing, error: &coordinatorError) { source, target in
            do {
                if from.lowercased() == destination.lowercased() {
                    // A case-only rename: go through a temporary name, since the file system
                    // considers the two names the same file.
                    let temporary = source.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)")
                    try FileManager.default.moveItem(at: source, to: temporary)
                    try FileManager.default.moveItem(at: temporary, to: target)
                } else {
                    try FileManager.default.moveItem(at: source, to: target)
                }
                coordinator.item(at: source, didMoveTo: target)
            } catch {
                moveError = error
            }
        }
        if let error = coordinatorError ?? moveError { throw error }
    }

    public func createFolder(_ path: String) throws {
        try FileManager.default.createDirectory(at: url(for: path), withIntermediateDirectories: true)
    }

    public func remove(_ path: String) throws {
        try coordinate(writing: url(for: path), options: .forDeleting) { url in
            try FileManager.default.removeItem(at: url)
        }
    }

    /// A free path for `name` in `folder`: `name.md`, else `name 2.md`, `name 3.md`…
    /// `current` (the note's own path) counts as free, so a note never collides with itself.
    public func uniquePath(in folder: String, name: String, extension ext: String = "md", current: String? = nil) -> String {
        var number = 1
        while true {
            let fileName = number == 1 ? "\(name).\(ext)" : "\(name) \(number).\(ext)"
            let candidate = folder.isEmpty ? fileName : "\(folder)/\(fileName)"
            if let current, candidate.lowercased() == current.lowercased() { return candidate }
            if !exists(candidate) { return candidate }
            number += 1
        }
    }

    // MARK: iCloud

    /// iCloud keeps both sides when two devices edit the same note while apart. Saves every other
    /// version as a "conflicted copy" note, so nothing is lost, and returns the new copies' paths.
    public func resolveConflicts(at path: String) -> [String] {
        let fileURL = url(for: path)
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: fileURL), !versions.isEmpty else { return [] }
        let folder = (path as NSString).deletingLastPathComponent
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var copies: [String] = []
        for version in versions {
            if let data = try? Data(contentsOf: version.url) {
                let copy = uniquePath(in: folder, name: "\(name) (conflicted copy)")
                if (try? write(String(decoding: data, as: UTF8.self), to: copy)) != nil { copies.append(copy) }
            }
            version.isResolved = true
        }
        try? NSFileVersion.removeOtherVersionsOfItem(at: fileURL)
        return copies
    }

    // MARK: Coordination

    private func coordinate(reading url: URL, _ body: (URL) throws -> Void) throws {
        var coordinatorError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinatorError) { url in
            do { try body(url) } catch { bodyError = error }
        }
        if let error = coordinatorError ?? bodyError { throw error }
    }

    private func coordinate(writing url: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> Void) throws {
        var coordinatorError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: options, error: &coordinatorError) { url in
            do { try body(url) } catch { bodyError = error }
        }
        if let error = coordinatorError ?? bodyError { throw error }
    }
}
