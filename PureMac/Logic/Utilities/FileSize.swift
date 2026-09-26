import Foundation
import Combine

/// Allocated-size calculation that works for both files and directories.
///
/// `URLResourceValues.totalFileAllocatedSize` does **not** recurse: on a
/// directory URL it returns only the directory inode's own allocation
/// (~96 bytes to a few KB on APFS), not the sum of the bundle's contents.
/// Reading it directly on an `.app` bundle or a support folder is what made
/// items display as a handful of bytes. For directories we enumerate and sum
/// the regular files instead.
enum FileSizeCalculator {
    private static let fileManager = FileManager.default

    /// On-disk allocated size of `url`. Recurses into directories.
    /// Returns `nil` if the item can't be read at all.
    static func size(of url: URL) -> Int64? {
        guard !Task.isCancelled else { return nil }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        // Treat a symlink as a file (size of the link itself), never recursing
        // into its target. `.isDirectoryKey` resolves symlinks, so without this
        // guard a top-level symlink-to-directory would be walked as the target's
        // full tree — inflating the size, escaping the item's real footprint,
        // and mismatching deletion (removeItem deletes only the link). Check
        // isSymbolicLink first so the directory branch only sees real dirs.
        if values?.isSymbolicLink != true, values?.isDirectory == true {
            return directorySize(of: url)
        }
        return fileSize(of: url, values: values)
    }

    private static func fileSize(of url: URL, values: URLResourceValues?) -> Int64? {
        if let size = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize {
            return Int64(size)
        }
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
        return size
    }

    private static func directorySize(of url: URL) -> Int64? {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard !Task.isCancelled else { return nil }
            guard let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else { continue }
            // Skip symlinks so we don't double-count or follow links that
            // escape the directory. Only sum regular-file payload.
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true else { continue }
            if let allocated = values.totalFileAllocatedSize {
                total += Int64(allocated)
            } else if let allocated = values.fileAllocatedSize {
                total += Int64(allocated)
            }
        }
        return total
    }
}

/// Owns measurement across view remounts. Selection/removal reuses results;
/// a new scan generation invalidates them, even if the returned paths match.
@MainActor
final class FileSizeCache: ObservableObject {
    typealias Measurement = @Sendable (URL) -> Int64?
    @Published private(set) var sizes: [URL: Int64] = [:]
    private var generation: UUID?
    private var requestID = UUID()
    private var worker: Task<[URL: Int64], Error>?
    private let measure: Measurement

    init(measure: @escaping Measurement = { FileSizeCalculator.size(of: $0) }) {
        self.measure = measure
    }

    deinit { worker?.cancel() }

    func update(_ urls: [URL], generation: UUID) async {
        worker?.cancel()
        let id = UUID()
        requestID = id
        if self.generation != generation {
            sizes = [:]
            self.generation = generation
        }
        let allowed = Set(urls)
        sizes = sizes.filter { allowed.contains($0.key) }
        let pending = urls.filter { sizes[$0] == nil }
        guard !pending.isEmpty else { worker = nil; return }
        let measure = self.measure
        let task = Task.detached(priority: .utility) { () throws -> [URL: Int64] in
            var result: [URL: Int64] = [:]
            for url in pending {
                try Task.checkCancellation()
                result[url] = measure(url) ?? 0
            }
            try Task.checkCancellation()
            return result
        }
        worker = task
        do {
            let measured = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard !Task.isCancelled, requestID == id else { return }
            sizes.merge(measured) { _, new in new }
        } catch { /* Canceled generations never publish partial measurements. */ }
        if requestID == id { worker = nil }
    }
}
