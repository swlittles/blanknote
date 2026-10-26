import BlankNoteCore
import SwiftUI

struct SidebarView: View {
    @Bindable var nav: Navigator
    @Environment(NoteStore.self) private var store
    @State private var renaming: String?
    @State private var folderName = ""
    @State private var deleting: String?

    var body: some View {
        List(selection: $nav.sidebar) {
            Section {
                ProfileSwitcher(nav: nav)
                    .sidebarRow(nav.isCompact)
            }
            Section {
                SidebarLabel("All Notes", systemImage: "note.text")
                    .badge(store.notes.count { !$0.isTrashed })
                    .tag(SidebarItem.all)
                    .sidebarRow(nav.isCompact)
                    .dropDestination(for: String.self) { paths, _ in
                        nav.move(paths, to: "")
                        return true
                    }
            }
            Section("Folders") {
                OutlineGroup(FolderNode.tree(store.folders), children: \.children) { node in
                    folderRow(node)
                }
            }
            let tags = store.tagCounts
            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags, id: \.tag) { item in
                        SidebarLabel(item.tag, systemImage: "number")
                            .badge(item.count)
                            .tag(SidebarItem.tag(item.tag))
                            .sidebarRow(nav.isCompact)
                    }
                }
            }
            Section {
                SidebarLabel("Recently Deleted", systemImage: "trash")
                    .badge(store.notes.count(where: \.isTrashed))
                    .tag(SidebarItem.trash)
                    .sidebarRow(nav.isCompact)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.sidebarColor)
        .navigationTitle("BlankNote")
        .toolbar {
            ToolbarItem {
                Button {
                    nav.newFolderParent = ""
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
            }
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    nav.settingsRoute = .general
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            #endif
        }
        .alert("New Folder", isPresented: Binding(get: { nav.newFolderParent != nil }, set: { if !$0 { nav.newFolderParent = nil } })) {
            TextField("Name", text: $folderName)
            Button("Cancel", role: .cancel) { folderName = "" }
            Button("Create") {
                nav.createFolder(named: folderName, in: nav.newFolderParent ?? "")
                folderName = ""
            }
        }
        .alert("Rename Folder", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $folderName)
            Button("Cancel", role: .cancel) { folderName = "" }
            Button("Rename") {
                if let path = renaming {
                    let name = folderName
                    Task { await nav.renameFolder(path, to: name) }
                }
                folderName = ""
            }
        }
        .confirmationDialog(
            "Delete “\((deleting.map { ($0 as NSString).lastPathComponent }) ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                if let path = deleting { nav.deleteFolder(path) }
            }
        } message: {
            Text("Its notes move to Recently Deleted.")
        }
    }

    private func folderRow(_ node: FolderNode) -> some View {
        SidebarLabel(node.name, systemImage: "folder")
            .badge(store.notes.count { $0.folder == node.path })
            .tag(SidebarItem.folder(node.path))
            .sidebarRow(nav.isCompact)
            .dropDestination(for: String.self) { paths, _ in
                nav.move(paths, to: node.path)
                return true
            }
            .contextMenu {
                Button("New Folder Inside", systemImage: "folder.badge.plus") { nav.newFolderParent = node.path }
                Button("Rename…", systemImage: "pencil") {
                    folderName = node.name
                    renaming = node.path
                }
                Divider()
                Button("Delete Folder", systemImage: "trash", role: .destructive) { deleting = node.path }
            }
    }
}

/// On iPhone the sidebar is a plain list of cards: give them the theme's card colour, so the
/// profile's tint reaches them. (On iPad and the Mac, sidebar rows have no background.)
/// `compact` is the window's size class: inside a split view the sidebar column is always compact.
private extension View {
    @ViewBuilder
    func sidebarRow(_ compact: Bool) -> some View {
        #if os(iOS)
        if compact {
            listRowBackground(Color(Palette.card))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// A sidebar row's label with its icon in the theme's accent. (Mac sidebars otherwise use the
/// app-wide accent colour, which doesn't follow the profile.)
private struct SidebarLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Palette.accentColor)
        }
    }
}
