import Foundation
#if os(macOS)
import CoreServices
#endif

/// Calls `onChange` (on the main queue) when something changes in the notes folder, whether
/// iCloud brought in an edit from another device or another app wrote a file.
final class FolderWatcher {
    private let onChange: () -> Void
    private var metadataQuery: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    #if os(macOS)
    private var stream: FSEventStreamRef?
    #endif

    init(root: URL, iCloud: Bool, onChange: @escaping () -> Void) {
        self.onChange = onChange
        if iCloud { startMetadataQuery() }
        #if os(macOS)
        // On the Mac other apps (editors, git, Claude Code) can change the files directly.
        startEventStream(root: root)
        #endif
    }

    deinit {
        metadataQuery?.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        #if os(macOS)
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        #endif
    }

    private func startMetadataQuery() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                self?.downloadMissing(query)
                self?.onChange()
            })
        }
        query.start()
        metadataQuery = query
    }

    /// Asks iCloud to download every note that is only a placeholder on this device.
    private func downloadMissing(_ query: NSMetadataQuery) {
        query.disableUpdates()
        defer { query.enableUpdates() }
        for case let item as NSMetadataItem in query.results {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String,
                  status == NSMetadataUbiquitousItemDownloadingStatusNotDownloaded else { continue }
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
    }

    #if os(macOS)
    private func startEventStream(root: URL) {
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }
    #endif
}
