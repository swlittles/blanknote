import Foundation

/// The top-level folder holding every profile's notes: the app's iCloud Drive folder when iCloud is
/// available, otherwise its Documents folder.
public enum NotesContainer {
    /// iCloud Drive when the app has a container and the user is signed in; Documents otherwise.
    /// Notes written locally before iCloud became available are moved into iCloud.
    public static func resolve(useICloud: Bool) -> (URL, NoteStore.Location) {
        let local = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if useICloud, let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            let documents = container.appendingPathComponent("Documents", isDirectory: true)
            try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            moveLocalNotes(from: local, intoICloud: documents)
            return (documents, .iCloud)
        }
        return (local, .local)
    }

    private static func moveLocalNotes(from local: URL, intoICloud documents: URL) {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) else { return }
        for item in items where !item.lastPathComponent.hasPrefix(".") || item.lastPathComponent == NoteFileSystem.trashFolder {
            var target = documents.appendingPathComponent(item.lastPathComponent)
            var number = 2
            while manager.fileExists(atPath: target.path) {
                let base = item.deletingPathExtension().lastPathComponent
                let ext = item.pathExtension
                target = documents.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
                number += 1
            }
            try? manager.setUbiquitous(true, itemAt: item, destinationURL: target)
        }
    }

}
