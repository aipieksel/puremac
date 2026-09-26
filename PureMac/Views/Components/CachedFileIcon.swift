import AppKit
import SwiftUI

// Immutable ownership transfer; the cached image is never mutated after load.
private struct LoadedFileIcon: @unchecked Sendable { let image: NSImage }
private actor FileIconLoader {
    func load(_ path: String) -> LoadedFileIcon {
        LoadedFileIcon(image: NSWorkspace.shared.icon(forFile: path))
    }
}

@MainActor
final class FileIconCache {
    static let shared = FileIconCache()
    private let cache = NSCache<NSString, Entry>()
    private var pending: [String: Task<LoadedFileIcon, Never>] = [:]

    private final class Entry {
        let image: NSImage
        let expires = Date().addingTimeInterval(60)
        init(_ image: NSImage) { self.image = image }
    }

    private let load: (String) async -> NSImage
    init(load: ((String) async -> NSImage)? = nil) {
        let loader = FileIconLoader()
        self.load = load ?? { await loader.load($0).image }
        cache.countLimit = 256
    }

    func icon(for path: String) async -> NSImage {
        if let entry = cache.object(forKey: path as NSString), entry.expires > Date() {
            return entry.image
        }
        if let task = pending[path] { return await task.value.image }
        let task = Task { LoadedFileIcon(image: await load(path)) }
        pending[path] = task
        let image = await task.value.image
        pending[path] = nil
        cache.setObject(Entry(image), forKey: path as NSString)
        return image
    }
}

/// Only realized rows request icons. Rendering or toggling a row does no I/O.
struct CachedFileIcon: View {
    let url: URL
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable() }
            else { Image(systemName: "doc").resizable() }
        }
        .task(id: url.path) {
            icon = nil
            let loaded = await FileIconCache.shared.icon(for: url.path)
            guard !Task.isCancelled else { return }
            icon = loaded
        }
    }
}
