import BlankNoteCore
import SwiftUI

extension ProfileTheme {
    /// The accent as a SwiftUI colour (for swatches and badges, which show a profile's own
    /// colour whatever the active theme).
    var accentColor: Color { Color(PlatformColor(hex: accent)) }
}

/// A profile's coloured circle with its initial.
struct ProfileBadge: View {
    let profile: Profile
    var size: CGFloat = 24

    var body: some View {
        Circle()
            .fill(profile.theme.accentColor.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(profile.initial)
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// The top of the sidebar: the active profile, and a menu to switch or add one.
struct ProfileSwitcher: View {
    let nav: Navigator
    @Environment(AppModel.self) private var app
    @Environment(NoteStore.self) private var store

    var body: some View {
        if let active = app.activeProfile {
            Menu {
                ForEach(app.profiles.profiles) { profile in
                    Button {
                        app.switchTo(profile.id)
                    } label: {
                        if profile.id == active.id {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
                Divider()
                Button("New Profile…", systemImage: "plus") { nav.showNewProfile = true }
                #if os(macOS)
                SettingsLink {
                    Label("Manage Profiles…", systemImage: "slider.horizontal.3")
                }
                #else
                Button("Manage Profiles…", systemImage: "slider.horizontal.3") { nav.settingsRoute = .profiles }
                #endif
            } label: {
                HStack(spacing: 10) {
                    ProfileBadge(profile: active, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(active.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(noteCount)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("Profile: \(active.name)")
            .accessibilityHint("Switch profiles")
            .accessibilityIdentifier("profileSwitcher")
        }
    }

    private var noteCount: String {
        let count = store.notes.count { !$0.isTrashed }
        return count == 1 ? "1 note" : "\(count) notes"
    }
}

/// Preset colours, a custom colour, and whether the colour tints the backgrounds.
struct ThemePicker: View {
    @Binding var theme: ProfileTheme
    @Environment(\.self) private var environment

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40, maximum: 52), spacing: 10)], spacing: 10) {
            ForEach(ProfileTheme.presets) { preset in
                Button {
                    theme = preset.theme
                } label: {
                    Circle()
                        .fill(preset.theme.accentColor.gradient)
                        .frame(width: 32, height: 32)
                        .padding(4)
                        .overlay {
                            if theme.presetName == preset.name {
                                Circle().strokeBorder(preset.theme.accentColor, lineWidth: 2.5)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(preset.name)
                .accessibilityLabel(preset.name)
                .accessibilityAddTraits(theme.presetName == preset.name ? .isSelected : [])
                .accessibilityIdentifier("theme.\(preset.name)")
            }
        }
        .padding(.vertical, 4)
        ColorPicker(selection: customColor, supportsOpacity: false) {
            LabeledContent("Custom Color", value: theme.presetName == nil ? String(format: "#%06X", theme.accent) : "")
        }
        Toggle("Tint Backgrounds", isOn: $theme.tintsBackground)
    }

    private var customColor: Binding<Color> {
        Binding {
            theme.accentColor
        } set: { color in
            let resolved = color.resolve(in: environment)
            func channel(_ value: Float) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
            theme.accent = channel(resolved.red) << 16 | channel(resolved.green) << 8 | channel(resolved.blue)
        }
    }
}

/// The sheet for making a profile: a name and a theme.
struct NewProfileView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var theme = ProfileTheme.claude
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Work, Acme Corp, Side Project…"))
                        .focused($nameFocused)
                        .onSubmit(create)
                        .accessibilityIdentifier("profileName")
                } footer: {
                    Text("A profile has its own notes, folders, tags and search.")
                }
                Section("Theme") {
                    ThemePicker(theme: $theme)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Profile")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(width: 440, height: 420)
        #endif
        .onAppear {
            theme = ProfileStore.nextTheme(after: app.profiles.profiles)
            nameFocused = true
        }
    }

    private func create() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if app.createProfile(name: name, theme: theme) != nil { dismiss() }
    }
}

/// Settings › Profiles: every profile, to edit, reorder or delete.
struct ProfilesSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var showNew = false

    var body: some View {
        Form {
            Section {
                ForEach(app.profiles.profiles) { profile in
                    NavigationLink {
                        ProfileEditor(profileID: profile.id)
                    } label: {
                        HStack(spacing: 10) {
                            ProfileBadge(profile: profile, size: 26)
                            Text(profile.name)
                            Spacer()
                            if profile.id == app.activeProfile?.id {
                                Text("Current")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("profile.\(profile.name)")
                }
                .onMove { from, to in
                    var ids = app.profiles.profiles.map(\.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    app.reorder(ids)
                }
                Button("New Profile…", systemImage: "plus") { showNew = true }
            } footer: {
                Text("Each profile has its own notes, folders, tags and search, and its own colours. Profiles sync to all your devices. Drag to reorder.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Profiles")
        .sheet(isPresented: $showNew) {
            ThemeTinted { NewProfileView() }
                .environment(app)
        }
    }
}

/// One profile's name, theme, and the way to delete it.
struct ProfileEditor: View {
    let profileID: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var theme = ProfileTheme.claude
    @State private var confirmDelete = false
    @State private var loaded = false

    var body: some View {
        Form {
            if let profile {
                Section("Name") {
                    TextField("Name", text: $name)
                        .onSubmit(saveName)
                        .accessibilityIdentifier("profileName")
                }
                Section {
                    ThemePicker(theme: $theme)
                } header: {
                    Text("Theme")
                } footer: {
                    Text(profile.id == app.activeProfile?.id
                         ? "The app changes colour as you pick."
                         : "You'll see these colours when you switch to this profile.")
                }
                Section {
                    if profile.id != app.activeProfile?.id {
                        Button("Switch to \(profile.name)") { app.switchTo(profile.id) }
                    }
                    Button("Delete Profile…", role: .destructive) { confirmDelete = true }
                        .disabled(app.profiles.profiles.count == 1)
                } footer: {
                    if app.profiles.profiles.count == 1 {
                        Text("You need at least one profile.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(profile?.name ?? "Profile")
        .onAppear(perform: load)
        .onChange(of: theme) {
            guard loaded else { return }
            app.setTheme(theme, for: profileID)
        }
        .onDisappear(perform: saveName)
        .confirmationDialog("Delete “\(profile?.name ?? "")”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Profile and Its Notes", role: .destructive) {
                app.delete(profileID)
                dismiss()
            }
        } message: {
            Text("Its notes will no longer appear in BlankNote. A copy is kept in the hidden “.deleted-profiles” folder of BlankNote's iCloud Drive folder.")
        }
    }

    private var profile: Profile? {
        app.profiles.profiles.first { $0.id == profileID }
    }

    private func load() {
        guard !loaded, let profile else { return }
        name = profile.name
        theme = profile.theme
        DispatchQueue.main.async { loaded = true }
    }

    private func saveName() {
        guard loaded, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        app.rename(profileID, to: name)
    }
}

#if os(iOS)
/// Settings as a sheet on iPhone and iPad, optionally opened on the Profiles page.
struct SettingsSheet: View {
    let store: NoteStore
    let route: SettingsRoute
    @Environment(\.dismiss) private var dismiss
    @State private var path: [SettingsRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            SettingsView(store: store)
                .navigationDestination(for: SettingsRoute.self) { route in
                    switch route {
                    case .profiles: ProfilesSettingsView()
                    case .general: EmptyView()
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .onAppear {
            if route == .profiles { path = [.profiles] }
        }
    }
}
#endif
