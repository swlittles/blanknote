import Foundation
import Observation

/// The profiles in the notes container, and which one this device is using.
///
/// Each profile is a top-level folder of the container with a hidden `.inkwell-profile.json`
/// (name, theme, order). Profiles sync like notes do; the active profile is per device.
@MainActor @Observable
public final class ProfileStore {
    public static let metadataFile = ".inkwell-profile.json"
    /// Deleted profiles' folders go here (hidden, so they can still be recovered in Finder).
    public static let deletedFolder = ".deleted-profiles"

    /// Written at the top of the container while notes from before profiles move into the first
    /// profile, so an interrupted move is finished next time (and nothing is mistaken for a profile).
    static let migrationMarker = ".inkwell-migrating"

    public enum ProfileError: LocalizedError {
        case lastProfile
        case notFound
        case notDownloaded

        public var errorDescription: String? {
            switch self {
            case .lastProfile: "You need at least one profile."
            case .notFound: "That profile no longer exists."
            case .notDownloaded: "That profile hasn't finished downloading from iCloud yet."
            }
        }
    }

    /// Sorted by `order`.
    public private(set) var profiles: [Profile] = []
    public private(set) var activeID: UUID?
    public private(set) var containerURL: URL?
    public private(set) var location: NoteStore.Location = .local
    public private(set) var isReady = false

    @ObservationIgnored private let containerOverride: URL?
    @ObservationIgnored private let useICloud: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let activeKey: String
    @ObservationIgnored private var startTask: Task<Void, Never>?
    /// Profiles shown under their folder name because their settings file hasn't downloaded yet:
    /// nothing is written for them, so the real settings aren't overwritten when they arrive.
    @ObservationIgnored private var pending: Set<UUID> = []
    /// Profiles whose settings file couldn't be read. They're never rewritten on their own, only
    /// when the user changes them.
    @ObservationIgnored private var unreadable: Set<UUID> = []

    /// `container` replaces iCloud Drive / Documents (tests, demo data).
    public init(container: URL? = nil, useICloud: Bool = true, defaults: UserDefaults = .standard) {
        containerOverride = container
        self.useICloud = useICloud
        self.defaults = defaults
        activeKey = container == nil ? "activeProfileID" : "activeProfileID.\(container!.lastPathComponent)"
    }

    public var active: Profile? {
        profiles.first { $0.id == activeID } ?? profiles.first
    }

    public func folderURL(for profile: Profile) -> URL? {
        containerURL?.appendingPathComponent(profile.folderName, isDirectory: true)
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
        let (container, location): (URL, NoteStore.Location)
        if let containerOverride {
            (container, location) = (containerOverride, .local)
        } else {
            let useICloud = self.useICloud
            (container, location) = await Task.detached(priority: .userInitiated) { NotesContainer.resolve(useICloud: useICloud) }.value
        }
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        containerURL = container
        self.location = location
        finishMigration()
        refresh()
        if profiles.isEmpty { createFirstProfile() }
        if activeID == nil {
            let saved = defaults.string(forKey: activeKey).flatMap(UUID.init(uuidString:))
            activeID = profiles.first { $0.id == saved }?.id ?? profiles.first?.id
        }
        isReady = true
    }

    /// Re-reads the profiles from the container (another device may have added or changed one).
    public func refresh() {
        guard let containerURL else { return }
        let fileSystem = NoteFileSystem(root: containerURL)
        let directories = ((try? FileManager.default.contentsOfDirectory(
            at: containerURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted()

        var found: [Profile] = []
        var unclaimed: [String] = []
        var seenIDs = Set<UUID>()
        pending = []
        unreadable = []
        for folder in directories {
            let metadataPath = "\(folder)/\(Self.metadataFile)"
            if fileSystem.exists(metadataPath) {
                if let text = try? fileSystem.read(metadataPath),
                   let metadata = try? Self.decoder.decode(Profile.Metadata.self, from: Data(text.utf8)) {
                    var profile = Profile(metadata: metadata, folderName: folder)
                    // A folder copied in Finder carries its original's ID: give the copy its own.
                    if !seenIDs.insert(profile.id).inserted {
                        profile.id = UUID()
                        try? write(profile)
                    }
                    found.append(profile)
                } else {
                    // Damaged, or written by a newer version: show the profile, but leave the file be.
                    let profile = Profile(id: Self.placeholderID(for: folder), name: folder, theme: .claude, order: Int.max, folderName: folder)
                    unreadable.insert(profile.id)
                    found.append(profile)
                }
            } else if fileSystem.exists("\(folder)/.\(Self.metadataFile).icloud") {
                // Not downloaded yet on this device: show it under its folder name meanwhile.
                try? FileManager.default.startDownloadingUbiquitousItem(at: containerURL.appendingPathComponent("\(folder)/.\(Self.metadataFile).icloud"))
                let profile = Profile(id: Self.placeholderID(for: folder), name: folder, theme: .claude, order: Int.max, folderName: folder)
                pending.insert(profile.id)
                found.append(profile)
            } else {
                unclaimed.append(folder)
            }
        }
        // Once profiles exist, a new top-level folder (say, made in Finder) is a new profile.
        // Before then, top-level folders are ordinary note folders waiting to move into the first
        // profile, and so are any left behind by an unfinished move.
        let migrating = FileManager.default.fileExists(atPath: containerURL.appendingPathComponent(Self.migrationMarker).path)
        if !found.isEmpty, !migrating {
            for folder in unclaimed {
                let profile = Profile(name: folder, theme: Self.nextTheme(after: found), order: (found.map(\.order).filter { $0 != Int.max }.max() ?? -1) + 1, folderName: folder)
                if (try? write(profile)) != nil { found.append(profile) }
            }
        }
        found.sort { ($0.order, $0.created) < ($1.order, $1.created) }
        if found != profiles { profiles = found }
        if let activeID, !profiles.contains(where: { $0.id == activeID }) { self.activeID = profiles.first?.id }
    }

    /// The first launch with profiles: everything already in the container (notes from before
    /// profiles existed) moves into a "Personal" profile.
    private func createFirstProfile() {
        guard let containerURL else { return }
        let fileSystem = NoteFileSystem(root: containerURL)
        let existing = migratableItems()
        let folder = uniqueFolderName("Personal", taken: Set(existing.map { $0.lowercased() }))
        let profile = Profile(name: "Personal", theme: .claude, order: 0, folderName: folder)
        do {
            // The marker and the profile first, so if moving stops partway the next launch knows
            // where the rest goes.
            if !existing.isEmpty { try fileSystem.write(folder, to: Self.migrationMarker) }
            try fileSystem.createFolder(folder)
            try write(profile)
            profiles = [profile]
        } catch {
            return
        }
        finishMigration()
    }

    /// Top-level items from before profiles: notes, note folders and Recently Deleted.
    private func migratableItems() -> [String] {
        guard let containerURL else { return [] }
        let fileSystem = NoteFileSystem(root: containerURL)
        return ((try? FileManager.default.contentsOfDirectory(atPath: containerURL.path)) ?? [])
            .filter { !$0.hasPrefix(".") || $0 == NoteFileSystem.trashFolder }
            .filter { !fileSystem.exists("\($0)/\(Self.metadataFile)") && !fileSystem.exists("\($0)/.\(Self.metadataFile).icloud") }
            .sorted()
    }

    /// Moves what's left of the notes from before profiles into the first profile.
    private func finishMigration() {
        guard let containerURL else { return }
        let fileSystem = NoteFileSystem(root: containerURL)
        guard fileSystem.exists(Self.migrationMarker), let folder = try? fileSystem.read(Self.migrationMarker),
              !folder.isEmpty, fileSystem.exists(folder) else { return }
        var movedAll = true
        for item in migratableItems() where item != folder {
            var destination = "\(folder)/\(item)"
            let base = (item as NSString).deletingPathExtension
            let ext = (item as NSString).pathExtension
            var number = 2
            while fileSystem.exists(destination) {
                destination = "\(folder)/\(base) \(number)" + (ext.isEmpty ? "" : ".\(ext)")
                number += 1
            }
            do { try fileSystem.move(item, to: destination) } catch { movedAll = false }
        }
        if movedAll { try? fileSystem.remove(Self.migrationMarker) }
    }

    // MARK: Changes

    public func activate(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeID = id
        defaults.set(id.uuidString, forKey: activeKey)
    }

    /// The profile after (or before, with `step: -1`) the active one, wrapping around.
    public func neighbor(_ step: Int) -> Profile? {
        guard !profiles.isEmpty, let active, let index = profiles.firstIndex(of: active) else { return profiles.first }
        return profiles[(index + step % profiles.count + profiles.count) % profiles.count]
    }

    @discardableResult
    public func create(name: String, theme: ProfileTheme) throws -> Profile {
        guard let containerURL else { throw ProfileError.notFound }
        let fileSystem = NoteFileSystem(root: containerURL)
        let displayName = Self.cleanName(name)
        let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: containerURL.path)) ?? []).map { $0.lowercased() })
        let folder = uniqueFolderName(NoteText.fileName(for: displayName), taken: taken)
        let profile = Profile(name: displayName, theme: theme, order: (profiles.map(\.order).filter { $0 != Int.max }.max() ?? -1) + 1, folderName: folder)
        try fileSystem.createFolder(folder)
        try write(profile)
        profiles.append(profile)
        return profile
    }

    /// Renames the profile and its folder (when the new name is free as a folder name).
    public func rename(_ id: UUID, to name: String) throws {
        guard let containerURL, var profile = profiles.first(where: { $0.id == id }) else { throw ProfileError.notFound }
        guard !pending.contains(id) else { throw ProfileError.notDownloaded }
        profile.name = Self.cleanName(name)
        let wanted = NoteText.fileName(for: profile.name)
        if wanted != profile.folderName {
            let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: containerURL.path)) ?? [])
                .filter { $0.lowercased() != profile.folderName.lowercased() }
                .map { $0.lowercased() })
            let folder = uniqueFolderName(wanted, taken: taken)
            try NoteFileSystem(root: containerURL).move(profile.folderName, to: folder)
            profile.folderName = folder
        }
        try write(profile)
        unreadable.remove(id)
        replace(profile)
    }

    public func setTheme(_ theme: ProfileTheme, for id: UUID) throws {
        guard var profile = profiles.first(where: { $0.id == id }) else { throw ProfileError.notFound }
        guard !pending.contains(id) else { throw ProfileError.notDownloaded }
        guard profile.theme != theme else { return }
        profile.theme = theme
        try write(profile)
        unreadable.remove(id)
        replace(profile)
    }

    /// Puts these profiles first, in this order; the rest follow in their current order.
    public func reorder(_ ids: [UUID]) throws {
        let listed = ids.compactMap { id in profiles.first { $0.id == id } }
        var reordered: [Profile] = []
        for (order, var profile) in (listed + profiles.filter { !ids.contains($0.id) }).enumerated() {
            // Profiles without settings of their own get their order once they have them.
            if profile.order != order, !pending.contains(profile.id), !unreadable.contains(profile.id) {
                profile.order = order
                try write(profile)
            }
            reordered.append(profile)
        }
        profiles = reordered
    }

    /// Removes the profile from the list. Its folder (and every note in it) moves to the hidden
    /// `.deleted-profiles` folder rather than being erased.
    public func delete(_ id: UUID) throws {
        guard let containerURL, let profile = profiles.first(where: { $0.id == id }) else { throw ProfileError.notFound }
        guard profiles.count > 1 else { throw ProfileError.lastProfile }
        let stamp = Self.stampFormatter.string(from: Date())
        try NoteFileSystem(root: containerURL).move(profile.folderName, to: "\(Self.deletedFolder)/\(profile.folderName) \(stamp)")
        profiles.removeAll { $0.id == id }
        if activeID == id, let first = profiles.first { activate(first.id) }
    }

    // MARK: Helpers

    private func write(_ profile: Profile) throws {
        guard let containerURL else { throw ProfileError.notFound }
        let data = try Self.encoder.encode(profile.metadata)
        try NoteFileSystem(root: containerURL).write(String(decoding: data, as: UTF8.self), to: "\(profile.folderName)/\(Self.metadataFile)")
    }

    private func replace(_ profile: Profile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
    }

    private func uniqueFolderName(_ base: String, taken: Set<String>) -> String {
        var number = 1
        while true {
            let name = number == 1 ? base : "\(base) \(number)"
            if !taken.contains(name.lowercased()) { return name }
            number += 1
        }
    }

    static func cleanName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Profile" : String(trimmed.prefix(60))
    }

    /// A theme not used yet, so a new profile looks different from the others.
    public static func nextTheme(after profiles: [Profile]) -> ProfileTheme {
        let used = Set(profiles.map(\.theme))
        return ProfileTheme.presets.first { !used.contains($0.theme) }?.theme ?? ProfileTheme.presets[profiles.count % ProfileTheme.presets.count].theme
    }

    /// A stable ID for a profile whose file hasn't downloaded yet, from its folder name.
    static func placeholderID(for folder: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in folder.utf8.enumerated() { bytes[index % 16] = bytes[index % 16] &+ byte &* 31 &+ UInt8(index & 0xFF) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter
    }()
}
