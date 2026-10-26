import InkwellCore
import SwiftUI

/// A window: folders and tags, the note list, and the editor.
struct RootView: View {
    let store: NoteStore
    @State private var nav: Navigator
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #else
    @Environment(\.controlActiveState) private var controlActiveState
    #endif
    private let router = ActionRouter.shared

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
            #if DEBUG && os(macOS)
            DebugSelfTests.run(shortcuts: shortcuts)
            #endif
        }
        .onChange(of: router.requestCount) { handlePendingAction() }
        .onChange(of: store.notes) { nav.notesChanged() }
        .onChange(of: store.folders) { nav.notesChanged() }
        .onChange(of: store.lastError) { showStoreError() }
        .onChange(of: store.notices) { showStoreNotices() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                router.activeNavigator = nav
                store.scheduleReconcile()
            } else {
                nav.editor.flush()
            }
        }
        #if os(iOS)
        .onChange(of: sizeClass, initial: true) { _, size in nav.isCompact = size == .compact }
        #else
        .onChange(of: controlActiveState, initial: true) { _, state in
            if state == .key { router.activeNavigator = nav }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            nav.editor.flush()
        }
        .onDisappear { nav.editor.flush() }
        #endif
    }

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
                nav.toasts.show("“\(title)” was edited on two devices at once. Both versions were kept.",
                                systemImage: "doc.on.doc")
            }
        }
        store.clearNotices()
    }
}
