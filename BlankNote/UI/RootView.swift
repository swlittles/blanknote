import BlankNoteCore
import SwiftUI

/// A window: folders and tags, the note list, and the editor.
struct RootView: View {
    let store: NoteStore
    @State private var nav: Navigator
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// iPad: whether the sidebar is showing (`.detailOnly` when it's hidden).
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    #else
    @Environment(\.controlActiveState) private var controlActiveState
    #endif
    private let router = ActionRouter.shared

    init(store: NoteStore) {
        self.store = store
        _nav = State(initialValue: Navigator(store: store))
    }

    var body: some View {
        // Redrawn from scratch in the new colours when the theme changes; the navigator (what's
        // selected, the open note) carries over. Sheets sit outside it so they stay open.
        let themeRevision = ThemeState.shared.revision
        columns
        .id(themeRevision)
        .tint(Palette.accentColor)
        .sheet(isPresented: $nav.showNewProfile) {
            ThemeTinted { NewProfileView() }
                .environment(app)
        }
        #if os(iOS)
        .sheet(item: $nav.settingsRoute) { route in
            ThemeTinted {
                SettingsSheet(store: store, route: route)
            }
            .environment(app)
            .environment(shortcuts)
        }
        #endif
        .overlay(alignment: ToastOverlay.edge == .top ? .top : .bottom) {
            ToastOverlay(toaster: nav.toasts)
        }
        .environment(store)
        .focusedSceneValue(\.navigator, nav)
        .task {
            if router.activeNavigator == nil { router.activeNavigator = nav }
            #if os(macOS)
            GlobalHotkeys.shared.openMainWindow = { [openWindow] in openWindow(id: "main") }
            GlobalHotkeys.shared.start(with: shortcuts)
            #endif
            await store.start()
            nav.applyLaunchOptions()
            handlePendingAction()
            if let notice = app.takeNotice() { nav.toasts.show(notice, systemImage: "person.crop.circle") }
            #if DEBUG && os(macOS)
            DebugSelfTests.run(shortcuts: shortcuts)
            #endif
        }
        .onChange(of: router.requestCount) { handlePendingAction() }
        .onChange(of: store.notes) { nav.notesChanged() }
        .onChange(of: store.folders) { nav.notesChanged() }
        .onChange(of: store.indexRevision) { nav.indexChanged() }
        .onChange(of: store.lastError) { showStoreError() }
        .onChange(of: app.lastError) {
            if let message = app.lastError {
                app.lastError = nil
                nav.toasts.show(message, systemImage: "exclamationmark.triangle.fill", style: .error)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .blankNoteWillSwitchProfile)) { _ in nav.editor.close() }
        .onReceive(NotificationCenter.default.publisher(for: .blankNoteSaveEditors)) { _ in nav.editor.flush() }
        .onChange(of: store.notices) { showStoreNotices() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                router.activeNavigator = nav
                app.refresh()
                store.scheduleReconcile()
            } else {
                nav.editor.flush()
            }
        }
        #if os(iOS)
        .onChange(of: sizeClass, initial: true) { updateCompact() }
        .onChange(of: columnVisibility) { updateCompact() }
        #else
        .onChange(of: controlActiveState, initial: true) { _, state in
            if state == .key { router.activeNavigator = nav }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            nav.editor.close()
        }
        // The window closed (or shows another profile now): save, and drop a note left empty.
        .onDisappear { nav.editor.close() }
        #endif
    }

    @ViewBuilder private var columns: some View {
        #if os(iOS)
        if sizeClass == .regular {
            iPadColumns
        } else {
            threeColumns
        }
        #else
        threeColumns
        #endif
    }

    /// The Mac, and the iPhone (where it collapses into one stack).
    private var threeColumns: some View {
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
    }

    #if os(iOS)
    /// iPad. Three columns leave too little room for the note, so with the sidebar showing the rest of
    /// the window works like the iPhone (the list, then the note in its place); with the sidebar hidden
    /// the list and the note sit side by side.
    private var iPadColumns: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(nav: nav)
        } detail: {
            if columnVisibility == .detailOnly {
                HStack(spacing: 0) {
                    NavigationStack { NoteListView(nav: nav) }
                        .frame(width: 340)
                    Divider()
                    NavigationStack { EditorPane(nav: nav) }
                }
            } else {
                NavigationStack(path: openNotePath) {
                    NoteListView(nav: nav)
                        .navigationDestination(for: String.self) { _ in EditorPane(nav: nav) }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// The open note as a navigation path: opening one pushes it, going back closes it.
    private var openNotePath: Binding<[String]> {
        Binding(get: { nav.selection.map { [$0] } ?? [] },
                set: { nav.selection = $0.last })
    }

    /// One note at a time on screen (iPhone, or iPad with the sidebar showing): after deleting a
    /// note, go back to the list rather than opening the next one.
    private func updateCompact() {
        nav.isCompact = sizeClass == .compact || columnVisibility != .detailOnly
    }
    #endif

    /// Runs a global hotkey, Siri or Shortcuts request if it's for this window.
    private func handlePendingAction() {
        guard store.isReady, let action = router.take(for: nav) else { return }
        nav.handle(action)
    }

    /// Errors show as a notification in the active window rather than interrupting with an alert.
    private func showStoreError() {
        guard let message = store.lastError, router.activeNavigator == nil || router.activeNavigator === nav else { return }
        store.lastError = nil
        nav.toasts.show(message, systemImage: "exclamationmark.triangle.fill", style: .error)
    }

    private func showStoreNotices() {
        guard !store.notices.isEmpty, router.activeNavigator == nil || router.activeNavigator === nav else { return }
        for notice in store.notices {
            switch notice.kind {
            case .keptBothVersions(let title):
                nav.toasts.show("“\(title)” was changed somewhere else at the same time. Both versions were kept.",
                                systemImage: "doc.on.doc")
            case .savedAsNewNote(let title):
                nav.toasts.show("“\(title)” was moved or deleted somewhere else. Your changes were saved as a new note.",
                                systemImage: "doc.badge.plus")
            }
        }
        store.clearNotices()
    }
}
