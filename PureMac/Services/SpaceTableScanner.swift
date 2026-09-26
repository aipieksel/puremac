import Foundation
import Darwin

protocol SpaceTableScanning: Sendable {
    func discoverVolumes() -> [SpaceTableVolume]
    func scanDirectory(at path: String, progress: @escaping SpaceTableScanner.ProgressHandler) async throws -> SpaceTableScanResult
    func scanDirectory(at path: String, progress: @escaping SpaceTableScanner.ProgressHandler,
                       partial: @escaping @Sendable (SpaceTableScanResult) async -> Void) async throws -> SpaceTableScanResult
    func previewDirectory(at path: String) async throws -> SpaceTableScanResult
    func indexDirectoryTree(at path: String) async throws -> [String: SpaceTableScanResult]
    func indexDirectoryTree(at path: String, onBatch: @escaping @Sendable ([String: SpaceTableScanResult]) async -> Void) async throws
}

extension SpaceTableScanning {
    func scanDirectory(at path: String, progress: @escaping SpaceTableScanner.ProgressHandler,
                       partial: @escaping @Sendable (SpaceTableScanResult) async -> Void) async throws -> SpaceTableScanResult {
        try await scanDirectory(at: path, progress: progress)
    }

    func indexDirectoryTree(at path: String, onBatch: @escaping @Sendable ([String: SpaceTableScanResult]) async -> Void) async throws {
        let results = try await indexDirectoryTree(at: path)
        try Task.checkCancellation()
        await onBatch(results)
    }
}

actor SpaceTableScanner: SpaceTableScanning {
    typealias ProgressHandler = @Sendable (_ visitedItems: Int, _ discoveredBytes: Int64) -> Void

    private struct Bucket {
        let name: String
        let path: String
        let isDirectory: Bool
        let modificationDate: Date?
        var size: Int64
    }

    private struct BucketScanResult {
        let name: String
        let size: Int64
        let unreadableItemCount: Int
    }

    private struct ShardPlan {
        let pathGroups: [[String]]
        let directFileBytes: Int64
        let unreadableItemCount: Int
    }

    private struct DiskUsageMeasurement: Sendable {
        let bytes: Int64
        let hadReadError: Bool
    }

    actor ProcessLimiter {
        private var availablePermits: Int
        private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
        init(limit: Int) { availablePermits = max(1, limit) }

        func acquire() async throws {
            try Task.checkCancellation()
            if availablePermits > 0 { availablePermits -= 1; return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters.append((id, continuation))
                }
            } onCancel: { Task { await self.cancel(id) } }
            if Task.isCancelled { release(); throw CancellationError() }
        }

        private func cancel(_ id: UUID) {
            guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
            waiters.remove(at: index).1.resume(throwing: CancellationError())
        }

        func release() {
            if waiters.isEmpty { availablePermits += 1 }
            else { waiters.removeFirst().1.resume() }
        }
    }

    private final class ProgressAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private let handler: ProgressHandler
        private var visitedItems = 0
        private var discoveredBytes: Int64

        init(initialBytes: Int64, handler: @escaping ProgressHandler) {
            discoveredBytes = initialBytes
            self.handler = handler
        }

        func add(visited: Int, bytes: Int64) {
            lock.lock()
            visitedItems += visited
            discoveredBytes += bytes
            handler(visitedItems, discoveredBytes)
            lock.unlock()
        }
    }

    private let fileManager = FileManager.default
    private let maxConcurrentWorkers: Int
    private let shardAllDirectories: Bool
    private let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .fileSizeKey,
        .contentModificationDateKey
    ]

    init(
        maxConcurrentWorkers: Int = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount)),
        shardAllDirectories: Bool = false
    ) {
        self.maxConcurrentWorkers = max(1, maxConcurrentWorkers)
        self.shardAllDirectories = shardAllDirectories
    }

    nonisolated func discoverVolumes() -> [SpaceTableVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIsBrowsableKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? [URL(fileURLWithPath: "/")]

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable != false else { return nil }
            let total = Int64(values.volumeTotalCapacity ?? 0)
            guard total > 0 else { return nil }
            let available = values.volumeAvailableCapacityForImportantUsage
                ?? Int64(values.volumeAvailableCapacity ?? 0)
            return SpaceTableVolume(
                name: values.volumeName ?? (url.path == "/" ? "Macintosh HD" : url.lastPathComponent),
                path: url.path,
                totalSize: total,
                availableSize: max(0, available)
            )
        }
        .reduce(into: [String: SpaceTableVolume]()) { volumes, volume in
            volumes[volume.path] = volume
        }
        .values
        .sorted {
            if $0.path == "/" { return true }
            if $1.path == "/" { return false }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func scanDirectory(at path: String, progress: @escaping ProgressHandler) async throws -> SpaceTableScanResult {
        try await measureDirectory(at: path, progress: progress, partial: nil)
    }

    func scanDirectory(at path: String, progress: @escaping ProgressHandler,
                       partial: @escaping @Sendable (SpaceTableScanResult) async -> Void) async throws -> SpaceTableScanResult {
        try await measureDirectory(at: path, progress: progress, partial: partial)
    }

    private func measureDirectory(
        at path: String,
        progress: @escaping ProgressHandler,
        partial: (@Sendable (SpaceTableScanResult) async -> Void)?
    ) async throws -> SpaceTableScanResult {
        let rootURL = URL(fileURLWithPath: path).standardizedFileURL
        // A Photos library is a Finder package backed by a separately
        // protected TCC service. Space Table never needs Photos access, so do
        // not enumerate one even when the user scans its parent or a volume.
        // This keeps a declined Photos decision final instead of making macOS
        // ask again during later scans.
        if Self.isPhotoLibraryPackage(rootURL.path) {
            return SpaceTableScanResult(items: [], unreadableItemCount: 0)
        }
        let children = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        )

        var buckets: [String: Bucket] = [:]
        for child in children {
            try Task.checkCancellation()
            guard !shouldHide(child, rootPath: rootURL.path) else { continue }
            if Self.isPhotoLibraryPackage(child.path) {
                // Keep the package visible like Finder does, but make it a
                // non-browsable item and never request protected metadata.
                buckets[child.lastPathComponent] = Bucket(
                    name: child.lastPathComponent,
                    path: child.path,
                    isDirectory: false,
                    modificationDate: nil,
                    size: 0
                )
                continue
            }
            guard let values = try? child.resourceValues(forKeys: resourceKeys),
                  values.isSymbolicLink != true else { continue }
            buckets[child.lastPathComponent] = Bucket(
                name: child.lastPathComponent,
                path: child.path,
                isDirectory: values.isDirectory == true,
                modificationDate: values.contentModificationDate,
                size: values.isDirectory == true ? 0 : allocatedSize(values)
            )
        }

        let initialBytes = buckets.values.reduce(Int64(0)) { $0 + $1.size }
        let progressAccumulator = ProgressAccumulator(initialBytes: initialBytes, handler: progress)
        let processLimiter = ProcessLimiter(limit: maxConcurrentWorkers)
        let directoryBuckets = buckets.values.filter(\.isDirectory)
        var unreadableItemCount = 0

        if !directoryBuckets.isEmpty {
            let workerCount = min(maxConcurrentWorkers, directoryBuckets.count)
            var nextBucketIndex = 0

            try await withThrowingTaskGroup(of: BucketScanResult.self) { group in
                func submit(_ bucket: Bucket) {
                    group.addTask {
                        try await Self.scanBucket(
                            bucket,
                            scanRoot: rootURL.path,
                            workerCount: (self.shardAllDirectories || Self.shouldShard(
                                bucket,
                                scanRoot: rootURL.path
                            )) ? self.maxConcurrentWorkers : 1,
                            processLimiter: processLimiter,
                            progress: progressAccumulator
                        )
                    }
                }

                while nextBucketIndex < workerCount {
                    submit(directoryBuckets[nextBucketIndex])
                    nextBucketIndex += 1
                }

                while let result = try await group.next() {
                    if var bucket = buckets[result.name] {
                        bucket.size = result.size
                        buckets[result.name] = bucket
                    }
                    unreadableItemCount += result.unreadableItemCount
                    if let partial {
                        let rows = buckets.values.map {
                            SpaceTableItem(name: $0.name, path: $0.path, size: $0.size,
                                isDirectory: $0.isDirectory, modificationDate: $0.modificationDate)
                        }.sorted { $0.size > $1.size }
                        await partial(.init(items: rows, unreadableItemCount: unreadableItemCount))
                    }

                    if nextBucketIndex < directoryBuckets.count {
                        submit(directoryBuckets[nextBucketIndex])
                        nextBucketIndex += 1
                    }
                }
            }
        }

        try Task.checkCancellation()
        progressAccumulator.add(visited: 0, bytes: 0)

        let items = buckets.values
            .map {
                SpaceTableItem(
                    name: $0.name,
                    path: $0.path,
                    size: $0.size,
                    isDirectory: $0.isDirectory,
                    modificationDate: $0.modificationDate
                )
            }
            .sorted {
                if $0.size != $1.size { return $0.size > $1.size }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }

        return SpaceTableScanResult(items: items, unreadableItemCount: unreadableItemCount)
    }

    /// Returns direct children without recursively measuring directory sizes.
    ///
    /// This deliberately favors interaction latency over final size accuracy:
    /// the UI can expand a large folder immediately while `indexDirectoryTree`
    /// replaces the preview with fully measured results in the background.
    func previewDirectory(at path: String) throws -> SpaceTableScanResult {
        let rootURL = URL(fileURLWithPath: path).standardizedFileURL
        if Self.isPhotoLibraryPackage(rootURL.path) {
            return SpaceTableScanResult(items: [], unreadableItemCount: 0)
        }

        let children = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        )
        var items: [SpaceTableItem] = []
        var unreadableItemCount = 0
        items.reserveCapacity(children.count)

        for child in children {
            try Task.checkCancellation()
            guard !shouldHide(child, rootPath: rootURL.path) else { continue }
            if Self.isPhotoLibraryPackage(child.path) {
                items.append(
                    SpaceTableItem(
                        name: child.lastPathComponent,
                        path: child.path,
                        size: 0,
                        isDirectory: false,
                        modificationDate: nil
                    )
                )
                continue
            }

            guard let values = try? child.resourceValues(forKeys: resourceKeys) else {
                unreadableItemCount += 1
                continue
            }
            guard values.isSymbolicLink != true else { continue }
            let isDirectory = values.isDirectory == true
            items.append(
                SpaceTableItem(
                    name: child.lastPathComponent,
                    path: child.path,
                    size: isDirectory ? 0 : allocatedSize(values),
                    isDirectory: isDirectory,
                    modificationDate: values.contentModificationDate
                )
            )
        }

        items.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            if $0.size != $1.size { return $0.size > $1.size }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return SpaceTableScanResult(
            items: items,
            unreadableItemCount: unreadableItemCount
        )
    }

    /// Native post-order traversal publishes completed directories while the
    /// rest of the subtree is still being read. fts supplies stat metadata in
    /// the same walk, avoiding URL resource lookups and multiple global maps
    /// for every file. Directory inode blocks remain excluded, as before.
    func indexDirectoryTree(at path: String) async throws -> [String: SpaceTableScanResult] {
        try Task.checkCancellation()
        var results: [String: SpaceTableScanResult] = [:]
        for try await batch in Self.indexBatches(at: path) {
            try Task.checkCancellation()
            results.merge(batch) { _, new in new }
        }
        try Task.checkCancellation()
        return results
    }

    func indexDirectoryTree(at path: String, onBatch: @escaping @Sendable ([String: SpaceTableScanResult]) async -> Void) async throws {
        try Task.checkCancellation()
        for try await batch in Self.indexBatches(at: path) {
            try Task.checkCancellation()
            await onBatch(batch)
        }
        try Task.checkCancellation()
    }

    private nonisolated static func indexBatches(at path: String) -> AsyncThrowingStream<[String: SpaceTableScanResult], Error> {
        AsyncThrowingStream { continuation in
            let worker = Task.detached(priority: .utility) {
                do {
                    try buildDirectoryIndex(at: path) { continuation.yield($0) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }

    private nonisolated static func buildDirectoryIndex(
        at path: String,
        emit: ([String: SpaceTableScanResult]) -> Void
    ) throws {
        let rootPath = URL(fileURLWithPath: path).path
        if isPhotoLibraryPackage(rootPath) {
            emit([rootPath: .init(items: [], unreadableItemCount: 0)])
            return
        }
        guard let root = strdup(rootPath) else { throw POSIXError(.ENOMEM) }
        defer { free(root) }
        var roots: [UnsafeMutablePointer<CChar>?] = [root, nil]
        guard let tree = roots.withUnsafeMutableBufferPointer({
            fts_open($0.baseAddress!, FTS_PHYSICAL | FTS_NOCHDIR | FTS_COMFOLLOW, nil)
        }) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { fts_close(tree) }

        struct Directory {
            var items: [SpaceTableItem] = []
            var unreadable = 0
        }
        // Only directories on the active traversal stack need mutable state.
        var directories: [String: Directory] = [:]
        var batch: [String: SpaceTableScanResult] = [:]
        var lastEmission = ContinuousClock.now
        var visited = 0
        while true {
            errno = 0
            guard let entry = fts_read(tree) else {
                if errno != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                break
            }
            visited += 1
            if visited.isMultiple(of: 128) { try Task.checkCancellation() }
            let node = entry.pointee
            let itemPath = String(cString: node.fts_path)
            let parentPath = (itemPath as NSString).deletingLastPathComponent
            let kind = Int32(node.fts_info)
            if kind == FTS_D {
                if isPhotoLibraryPackage(itemPath) {
                    fts_set(tree, entry, FTS_SKIP)
                    directories[parentPath, default: Directory()].items.append(.init(
                        name: (itemPath as NSString).lastPathComponent, path: itemPath,
                        size: 0, isDirectory: false, modificationDate: nil))
                    continue
                }
                if itemPath == "/System/Volumes" {
                    fts_set(tree, entry, FTS_SKIP)
                    continue
                }
                directories[itemPath] = Directory()
                continue
            }
            if kind == FTS_DP || kind == FTS_DNR {
                guard var directory = directories.removeValue(forKey: itemPath) ??
                    (kind == FTS_DNR ? Directory() : nil) else { continue }
                if kind == FTS_DNR { directory.unreadable += 1 }
                directory.items.sort {
                    if $0.size != $1.size { return $0.size > $1.size }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                let result = SpaceTableScanResult(items: directory.items, unreadableItemCount: directory.unreadable)
                batch[itemPath] = result
                if itemPath != rootPath {
                    let modified = node.fts_statp.map { Date(timeIntervalSince1970: Double($0.pointee.st_mtimespec.tv_sec)) }
                    directories[parentPath, default: Directory()].items.append(.init(
                        name: (itemPath as NSString).lastPathComponent, path: itemPath,
                        size: result.items.reduce(0) { $0 + $1.size }, isDirectory: true, modificationDate: modified))
                }
                // Time and count bounds keep large indexes responsive without
                // issuing an observable update for each directory.
                if batch.count >= 128 || lastEmission.duration(to: .now) >= .milliseconds(150) {
                    emit(batch); batch.removeAll(keepingCapacity: true); lastEmission = .now
                }
                continue
            }
            if kind == FTS_SL || kind == FTS_SLNONE { continue }
            if kind == FTS_ERR || kind == FTS_NS || kind == FTS_DC {
                if itemPath == rootPath {
                    batch[rootPath] = .init(items: [], unreadableItemCount: 1)
                } else { directories[parentPath, default: Directory()].unreadable += 1 }
                continue
            }
            guard let metadata = node.fts_statp?.pointee else { continue }
            // Match native disk usage: allocated blocks, not logical file size.
            directories[parentPath, default: Directory()].items.append(.init(
                name: (itemPath as NSString).lastPathComponent, path: itemPath,
                size: max(0, Int64(metadata.st_blocks) * 512), isDirectory: false,
                modificationDate: Date(timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec))))
        }
        try Task.checkCancellation()
        if !batch.isEmpty { emit(batch) }
    }

    private nonisolated static func scanBucket(
        _ bucket: Bucket,
        scanRoot: String,
        workerCount: Int,
        processLimiter: ProcessLimiter,
        progress: ProgressAccumulator
    ) async throws -> BucketScanResult {
        let plan = makeShardPlan(
            for: bucket,
            scanRoot: scanRoot,
            targetGroupCount: workerCount
        )
        var bucketBytes = plan.directFileBytes
        var unreadableItemCount = plan.unreadableItemCount

        try await withThrowingTaskGroup(of: DiskUsageMeasurement.self) { group in
            for paths in plan.pathGroups {
                group.addTask {
                    var arguments = [
                        "-sk",
                        "-I", "*.photoslibrary",
                        "-I", "*.photolibrary",
                        "-I", "*.aplibrary"
                    ]
                    if scanRoot == "/", bucket.path == "/System" {
                        arguments += ["-I", "Volumes"]
                    }
                    var total: Int64 = 0
                    var hadReadError = false
                    for chunk in Self.argumentChunks(paths) {
                        try Task.checkCancellation()
                        let measurement = try await runDiskUsage(
                            arguments: arguments + chunk,
                            processLimiter: processLimiter
                        )
                        total += measurement.bytes
                        hadReadError = hadReadError || measurement.hadReadError
                    }
                    return DiskUsageMeasurement(bytes: total, hadReadError: hadReadError)
                }
            }

            for try await measurement in group {
                bucketBytes += measurement.bytes
                if measurement.hadReadError {
                    unreadableItemCount += 1
                }
            }
        }

        progress.add(visited: 1, bytes: bucketBytes)
        return BucketScanResult(
            name: bucket.name,
            size: bucketBytes,
            unreadableItemCount: unreadableItemCount
        )
    }

    /// Leaves ample room for the command, environment, and argv pointers.
    nonisolated static func argumentChunks(_ paths: [String]) -> [[String]] {
        var chunks: [[String]] = []
        var current: [String] = []
        var bytes = 0
        for path in paths {
            let cost = path.utf8.count + 1 + MemoryLayout<UnsafeRawPointer>.size
            if !current.isEmpty, bytes + cost > 32 * 1024 || current.count >= 128 {
                chunks.append(current)
                current = []
                bytes = 0
            }
            current.append(path)
            bytes += cost
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private nonisolated static func makeShardPlan(
        for bucket: Bucket,
        scanRoot: String,
        targetGroupCount: Int
    ) -> ShardPlan {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]
        var frontier = [bucket.path]
        var terminalPaths: [String] = []
        var directFileBytes: Int64 = 0
        var unreadableItemCount = 0

        while frontier.count + terminalPaths.count < targetGroupCount,
              !frontier.isEmpty {
            let path = frontier.removeFirst()
            let url = URL(fileURLWithPath: path)
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: []
            ) else {
                terminalPaths.append(path)
                unreadableItemCount += 1
                continue
            }

            var childDirectories: [String] = []
            var childFileBytes: Int64 = 0
            for child in children {
                if isPhotoLibraryPackage(child.path) {
                    continue
                }
                if scanRoot == "/", child.path == "/System/Volumes" {
                    continue
                }
                guard let values = try? child.resourceValues(forKeys: keys) else {
                    unreadableItemCount += 1
                    continue
                }
                if values.isSymbolicLink == true {
                    continue
                }
                if values.isDirectory == true {
                    childDirectories.append(child.path)
                } else {
                    childFileBytes += Int64(
                        values.totalFileAllocatedSize
                            ?? values.fileAllocatedSize
                            ?? values.fileSize
                            ?? 0
                    )
                }
            }

            if childDirectories.isEmpty {
                terminalPaths.append(path)
            } else {
                directFileBytes += childFileBytes
                frontier.append(contentsOf: childDirectories)
            }
        }

        let paths = frontier + terminalPaths
        let groupCount = min(max(1, targetGroupCount), max(1, paths.count))
        var pathGroups = Array(repeating: [String](), count: groupCount)
        for (index, path) in paths.enumerated() {
            pathGroups[index % groupCount].append(path)
        }

        return ShardPlan(
            pathGroups: pathGroups.filter { !$0.isEmpty },
            directFileBytes: directFileBytes,
            unreadableItemCount: unreadableItemCount
        )
    }

    private nonisolated static func shouldShard(
        _ bucket: Bucket,
        scanRoot: String
    ) -> Bool {
        if scanRoot == "/" {
            return [
                "/Applications",
                "/Library",
                "/System",
                "/Users",
                "/opt",
                "/private"
            ].contains(bucket.path)
        }
        return scanRoot == "/Users" || scanRoot.hasPrefix("/Users/")
    }

    private nonisolated static func runDiskUsage(
        arguments: [String],
        processLimiter: ProcessLimiter
    ) async throws -> DiskUsageMeasurement {
        try Task.checkCancellation()
        try await processLimiter.acquire()

        do {
            let pair = try await runDiskUsageProcess(arguments: arguments)
            await processLimiter.release()
            return DiskUsageMeasurement(bytes: pair.0, hadReadError: pair.1)
        } catch {
            await processLimiter.release()
            throw error
        }
    }

    private nonisolated static func runDiskUsageProcess(
        arguments: [String]
    ) async throws -> (Int64, Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = arguments
        let output = try await Subprocess.runAsync(process, timeout: 3600, discardStderr: true)
        guard let bytes = parseDiskUsageOutput(output.stdout) else { return (0, true) }
        return (bytes, output.status != 0)
    }

    private nonisolated static func parseDiskUsageOutput(_ data: Data) -> Int64? {
        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        var totalKilobytes: Int64 = 0
        var foundMeasurement = false
        for line in output.split(whereSeparator: \.isNewline) {
            guard let firstField = line.split(whereSeparator: \.isWhitespace).first,
                  let kilobytes = Int64(firstField) else {
                continue
            }
            totalKilobytes += kilobytes
            foundMeasurement = true
        }
        return foundMeasurement ? max(0, totalKilobytes * 1_024) : nil
    }

    private func allocatedSize(_ values: URLResourceValues) -> Int64 {
        Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
    }

    private func shouldHide(_ url: URL, rootPath: String) -> Bool {
        // Expanding System must not measure its mounted Data-volume mirror.
        if rootPath == "/System", url.lastPathComponent == "Volumes" { return true }
        guard rootPath == "/" else { return false }
        // These are virtual filesystems, mounted volumes, or aliases rather
        // than storage owned by the selected boot volume. Hidden on-disk
        // folders such as .Spotlight-V100 and .DocumentRevisions-V100 remain
        // visible and are measured like every other folder.
        return ["dev", "Volumes", "Network", ".vol"].contains(url.lastPathComponent)
    }

    private nonisolated static func isPhotoLibraryPackage(_ path: String) -> Bool {
        let protectedExtensions: Set<String> = [
            "photoslibrary",
            "photolibrary",
            "aplibrary"
        ]
        // This is a lexical exclusion, not a metadata request. Constructing
        // file URLs for every ancestor can perform extra filesystem work.
        return path.split(separator: "/").contains { component in
            guard let dot = component.lastIndex(of: "."), dot != component.startIndex else { return false }
            return protectedExtensions.contains(String(component[component.index(after: dot)...]).lowercased())
        }
    }
}
