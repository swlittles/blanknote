import InkwellCore
import SwiftUI

/// A window: folders and tags, the note list, and the editor.
struct RootView: View {
    let store: NoteStore
    @State private var nav: Navigator
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    init(store: NoteStore) {
        self.store = store
        _nav = State(initialValue: Navigator(store: store))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(nav: nav)
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
                #endif
        } content: {
            NoteListView(nav: nav)
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 440)
                #endif
        } detail: {
            EditorPane(nav: nav)
        }
        .environment(store)
        .focusedSceneValue(\.navigator, nav)
        .task {
            await store.start()
            nav.applyLaunchOptions()
        }
        .onChange(of: store.notes) { nav.notesChanged() }
        .onChange(of: store.folders) { nav.notesChanged() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.scheduleReconcile()
            } else {
                nav.editor.flush()
            }
        }
        #if os(iOS)
        .onChange(of: sizeClass, initial: true) { _, size in nav.isCompact = size == .compact }
        #else
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            nav.editor.flush()
        }
        .onDisappear { nav.editor.flush() }
        #endif
        .alert("Something went wrong", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }
}
