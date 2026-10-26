import InkwellCore
import SwiftUI

struct SidebarView: View {
    @Bindable var nav: Navigator
    @Environment(NoteStore.self) private var store
    @State private var renaming: String?
    @State private var folderName = ""
    @State private var deleting: String?
    #if os(iOS)
    @State private var showSettings = false
    #endif

    var body: some View {
        List(selection: $nav.sidebar) {
            Section {
                Label("All Notes", systemImage: "note.text")
                    .badge(store.notes.count { !$0.isTrashed })
                    .tag(SidebarItem.all)
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
                        Label(item.tag, systemImage: "number")
                            .badge(item.count)
                            .tag(SidebarItem.tag(item.tag))
                    }
                }
            }
            Section {
                Label("Recently Deleted", systemImage: "trash")
                    .badge(store.notes.count(where: \.isTrashed))
                    .tag(SidebarItem.trash)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.sidebarColor)
        .navigationTitle("Inkwell")
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
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            #endif
        }
        #if os(iOS)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(store: store)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
        }
        #endif
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
        Label(node.name, systemImage: "folder")
            .badge(store.notes.count { $0.folder == node.path })
            .tag(SidebarItem.folder(node.path))
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
