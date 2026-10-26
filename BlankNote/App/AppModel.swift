import Foundation
import BlankNoteCore
import Observation

extension Notification.Name {
    /// Posted just before the active profile changes, so windows save the note they have open.
    static let blankNoteWillSwitchProfile = Notification.Name("BlankNoteWillSwitchProfile")
    /// Posted before a change that other windows' open notes must not race (a note or folder
    /// moved, renamed or deleted), so every window saves what it has first.
    static let blankNoteSaveEditors = Notification.Name("BlankNoteSaveEditors")
}

/// The app's profiles and the open profile's notes. Every window shows the active profile;
/// switching replaces the `NoteStore` (and so each window's contents) and the theme.
@MainActor @Observable
final class AppModel {
    let profiles: ProfileStore
    /// The active profile's notes.
    private(set) var store: NoteStore?
    /// Something to tell the user once the new profile's window is up ("Switched to Acme Corp").
    private(set) var notice: String?
    var lastError: String?

    /// The profile whose notes `store` holds.
    @ObservationIgnored private var storeProfileID: UUID?
    @ObservationIgnored private var themeSaves: [UUID: Task<Void, Never>] = [:]

    init(profiles: ProfileStore) {
        self.profiles = profiles
    }

    func start() async {
        await profiles.start()
        if let name = LaunchOptions.profileName, let profile = profiles.profiles.first(where: { $0.name == name }) {
            profiles.activate(profile.id)
        }
        openActive()
    }

    /// Identifies the open store, so windows rebuild when it changes.
    var storeID: String { storeProfileID?.uuidString ?? "" }

    var activeProfile: Profile? { profiles.active }

    func takeNotice() -> String? {
        defer { notice = nil }
        return notice
    }

    // MARK: Switching

    func switchTo(_ id: UUID) {
        guard id != profiles.active?.id, let profile = profiles.profiles.first(where: { $0.id == id }) else { return }
        NotificationCenter.default.post(name: .blankNoteWillSwitchProfile, object: nil)
        profiles.activate(id)
        openActive()
        notice = "Switched to \(profile.name)"
    }

    func switchToNeighbor(_ step: Int) {
        if let profile = profiles.neighbor(step) { switchTo(profile.id) }
    }

    /// Re-reads the profiles (another device may have changed them) and follows any change to the
    /// active one.
    func refresh() {
        profiles.refresh()
        openActive()
    }

    private func openActive() {
        guard let profile = profiles.active, let folder = profiles.folderURL(for: profile) else { return }
        ThemeState.shared.apply(profile.theme)
        if profile.id == storeProfileID {
            // Same profile, perhaps renamed: follow its folder without reopening.
            store?.moveRoot(to: folder)
            return
        }
        storeProfileID = profile.id
        store = NoteStore(options: .init(
            root: folder,
            rootLocation: profiles.location,
            indexURL: LaunchOptions.indexFolder.appendingPathComponent("\(profile.id.uuidString).sqlite"),
            welcomeNote: LaunchOptions.isDemo ? nil : SampleNotes.welcome
        ))
    }

    // MARK: Editing profiles

    @discardableResult
    func createProfile(name: String, theme: ProfileTheme) -> Profile? {
        do {
            let profile = try profiles.create(name: name, theme: theme)
            switchTo(profile.id)
            return profile
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func rename(_ id: UUID, to name: String) {
        guard let profile = profiles.profiles.first(where: { $0.id == id }), profile.name != name.trimmingCharacters(in: .whitespaces) else { return }
        // The windows stay on the profile (only its folder moves), so they save rather than close.
        NotificationCenter.default.post(name: .blankNoteSaveEditors, object: nil)
        do {
            try profiles.rename(id, to: name)
            openActive()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Shows the theme straight away and saves it a moment later, so dragging through a colour
    /// picker doesn't write the file on every step.
    func setTheme(_ theme: ProfileTheme, for id: UUID) {
        if id == profiles.active?.id { ThemeState.shared.apply(theme) }
        themeSaves[id]?.cancel()
        themeSaves[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            do { try self.profiles.setTheme(theme, for: id) } catch { self.lastError = error.localizedDescription }
        }
    }

    func reorder(_ ids: [UUID]) {
        do { try profiles.reorder(ids) } catch { lastError = error.localizedDescription }
    }

    func delete(_ id: UUID) {
        let wasActive = id == profiles.active?.id
        if wasActive { NotificationCenter.default.post(name: .blankNoteWillSwitchProfile, object: nil) }
        do {
            let name = profiles.profiles.first { $0.id == id }?.name ?? ""
            try profiles.delete(id)
            openActive()
            let message = "Deleted the “\(name)” profile"
            if wasActive {
                // Shown by the windows that open on the next profile.
                notice = message
            } else {
                ActionRouter.shared.activeNavigator?.toasts.show(message, systemImage: "person.crop.circle")
            }
        } catch {
            lastError = error.localizedDescription
        }
    }
}
