import AppKit
import Foundation

@MainActor
final class SpaceTableViewModel: ObservableObject {
    typealias TrashHandler = @Sendable ([String]) async -> SpaceTableTrashResult
    nonisolated private static let defaultTrashHandler: TrashHandler = { paths in
        await SpaceTableViewModel.movePathsToTrash(paths)
    }

    @Published private(set) var volumes: [SpaceTableVolume] = []
    @Published var selectedVolume: SpaceTableVolume?
    @Published private(set) var items: [SpaceTableItem] = [] {
        didSet { scannedSize = items.reduce(0) { $0 + $1.size } }
    }
    @Published private(set) var navigationPath: [String] = []
    @Published private(set) var state: SpaceTableScanState = .idle
    @Published private(set) var unreadableItemCount = 0
    @Published private(set) var selectedItems: [String: SpaceTableItem] = [:]
    @Published private(set) var isBackgroundIndexing = false
    @Published private(set) var indexedFolderCount = 0
    @Published private(set) var deletionError: String?
    @Published private(set) var isMovingToTrash = false
    @Published private(set) var indexingRevision = 0

    private let scanner: any SpaceTableScanning
    private let backgroundScanner: any SpaceTableScanning
    private let previewScanner: any SpaceTableScanning
    private let interactiveScanner: any SpaceTableScanning
    private let indexStore: SpaceTableIndexStore
    private let trashHandler: TrashHandler
    private var scanGeneration = UUID()
    private var backgroundGeneration = UUID()
    private var scanTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var indexingTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var interactiveTask: Task<Void, Never>?
    private var interactiveQueue: [String] = []
    private var interactivePaths: Set<String> = []
    private var activeMeasurementPath: String?
    private var measurementGeneration = UUID()
    private var cachedResults: [String: SpaceTableScanResult] = [:]
    private var provisionalPaths: Set<String> = []
    private var cachedVolumePath: String?
    private var indexingQueue: [String] = []
    private var queuedPaths: Set<String> = []
    private var previewQueue: [String] = []
    private var previewQueuedPaths: Set<String> = []

    init(
        scanner: any SpaceTableScanning = SpaceTableScanner(),
        backgroundScanner: any SpaceTableScanning = SpaceTableScanner(maxConcurrentWorkers: 1),
        previewScanner: any SpaceTableScanning = SpaceTableScanner(),
        interactiveScanner: any SpaceTableScanning = SpaceTableScanner(shardAllDirectories: true),
        indexStore: SpaceTableIndexStore = SpaceTableIndexStore(),
        trashHandler: @escaping TrashHandler = SpaceTableViewModel.defaultTrashHandler
    ) {
        self.scanner = scanner
        self.backgroundScanner = backgroundScanner
        self.previewScanner = previewScanner
        self.interactiveScanner = interactiveScanner
        self.indexStore = indexStore
        self.trashHandler = trashHandler
    }

    deinit {
        scanTask?.cancel()
        restoreTask?.cancel()
        indexingTask?.cancel()
        previewTask?.cancel()
        persistenceTask?.cancel()
        interactiveTask?.cancel()
    }

    var currentPath: String? {
        navigationPath.last ?? selectedVolume?.path
    }

    // Each visible row asks for the denominator of its share. Recompute only
    // when the result changes, not once per row or selection update.
    private(set) var scannedSize: Int64 = 0

    var unrepresentedSystemSize: Int64 {
        guard navigationPath.count == 1, currentPath == selectedVolume?.path else {
            return 0
        }
        return max(0, (selectedVolume?.usedSize ?? 0) - scannedSize)
    }

    var selectedSize: Int64 {
        selectedItems.values.reduce(0) { $0 + $1.size }
    }

    var selectedCount: Int {
        selectedItems.count
    }

    func loadVolumes() {
        let discovered = scanner.discoverVolumes()
        volumes = discovered
        if let current = selectedVolume,
           let refreshed = discovered.first(where: { $0.path == current.path }) {
            selectedVolume = refreshed
        } else {
            selectedVolume = nil
        }
    }

    func selectVolume(_ volume: SpaceTableVolume) {
        let isSwitchingVolumes = selectedVolume?.path != volume.path
        if isSwitchingVolumes {
            cancelScan()
            cancelBackgroundIndexing()
            restoreTask?.cancel()
            restoreTask = nil
            cachedResults.removeAll()
            provisionalPaths.removeAll()
            cachedVolumePath = volume.path
            indexedFolderCount = 0
            indexingRevision &+= 1
        }
        selectedVolume = volume
        if let cached = cachedResults[volume.path] {
            navigationPath = [volume.path]
            apply(cached)
        } else {
            navigationPath = []
            items = []
            unreadableItemCount = 0
            state = .idle
        }
    }

    func openVolume(_ volume: SpaceTableVolume) {
        if selectedVolume?.path == volume.path, state.isScanning {
            return
        }
        selectVolume(volume)
        navigationPath = [volume.path]
        if let cached = cachedResults[volume.path] {
            apply(cached)
            enqueueForBackgroundIndexing(cached.items, refreshCached: true)
            return
        }

        state = .scanning(path: volume.path, discoveredBytes: 0)
        restoreTask = Task { [weak self, indexStore] in
            guard let self else { return }
            let restored = await indexStore.load(for: volume)
            guard !Task.isCancelled, self.selectedVolume?.path == volume.path else {
                return
            }
            self.restoreTask = nil
            if let restored, let root = restored[volume.path] {
                self.cachedResults = restored
                self.provisionalPaths.removeAll()
                self.cachedVolumePath = volume.path
                self.indexedFolderCount = restored.count
                self.indexingRevision &+= 1
                self.apply(root)
                self.enqueueForBackgroundIndexing(root.items, refreshCached: true)
            } else {
                self.scan(path: volume.path, force: false)
            }
        }
    }

    func closeVolume() {
        scheduleCachePersistence(delay: .zero)
        cancelScan()
        cancelBackgroundIndexing()
        restoreTask?.cancel()
        restoreTask = nil
        selectedVolume = nil
        navigationPath = []
        items = []
        unreadableItemCount = 0
        state = .idle
    }

    func scanSelectedVolume() {
        guard let volume = selectedVolume else { return }
        navigationPath = [volume.path]
        scan(path: volume.path, force: false)
    }

    func scanCurrentLocation() {
        guard let path = currentPath else { return }
        if navigationPath.isEmpty {
            navigationPath = [path]
        }
        scan(path: path, force: true)
    }

    func open(_ item: SpaceTableItem) {
        guard item.isDirectory, !state.isScanning else { return }
        navigationPath.append(item.path)
        scan(path: item.path, force: false)
    }

    func navigate(to path: String) {
        guard let index = navigationPath.firstIndex(of: path), !state.isScanning else { return }
        navigationPath = Array(navigationPath.prefix(through: index))
        scan(path: path, force: false)
    }

    func navigateBack() {
        guard navigationPath.count > 1, !state.isScanning else { return }
        navigationPath.removeLast()
        if let path = navigationPath.last {
            scan(path: path, force: false)
        }
    }

    func cancelScan() {
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        restoreTask?.cancel()
        restoreTask = nil
        if state.isScanning {
            state = navigationPath.isEmpty ? .idle : .complete
        }
    }

    func revealInFinder(_ item: SpaceTableItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    func isSelected(_ item: SpaceTableItem) -> Bool {
        selectedItems[item.path] != nil
    }

    func isIndexed(_ path: String) -> Bool {
        cachedResults[path] != nil && !provisionalPaths.contains(path)
    }

    func indexedChildren(of item: SpaceTableItem) -> [SpaceTableItem]? {
        _ = indexingRevision
        return cachedResults[item.path]?.items
    }

    /// Preview rows are published before recursive directory totals are known.
    /// Treat their zero as pending data rather than a real zero-byte folder.
    func isSizePending(_ item: SpaceTableItem) -> Bool {
        _ = indexingRevision
        guard item.isDirectory, item.size == 0 else { return false }
        let parentPath = URL(fileURLWithPath: item.path)
            .deletingLastPathComponent().path
        return provisionalPaths.contains(parentPath) && !isIndexed(item.path)
    }

    func prioritizeIndexing(_ item: SpaceTableItem) {
        guard item.isDirectory else { return }
        if cachedResults[item.path] == nil {
            prioritizePreview(at: item.path)
        }
        guard cachedResults[item.path] == nil || provisionalPaths.contains(item.path) else {
            return
        }
        // A queue reorder cannot preempt a large active background subtree.
        // Reserve a bounded measurement lane for folders the user opens.
        prioritizeMeasurement(at: item.path)
        if let ancestor = queuedPaths.first(where: {
            item.path.hasPrefix($0 + "/")
        }) {
            if let index = indexingQueue.firstIndex(of: ancestor) {
                indexingQueue.remove(at: index)
                indexingQueue.insert(ancestor, at: 0)
            }
            return
        }
        if let index = indexingQueue.firstIndex(of: item.path) {
            indexingQueue.remove(at: index)
        } else if queuedPaths.contains(item.path) {
            // The folder is already in the active batch.
            return
        } else {
            queuedPaths.insert(item.path)
        }
        indexingQueue.insert(item.path, at: 0)
        startBackgroundIndexingIfNeeded()
    }

    /// Reasserts work after the Space Table view returns to the foreground.
    /// Changing sidebar sections must never cancel indexing; this also repairs
    /// a queue if a transient filesystem error ended a worker early.
    func resumeBackgroundIndexing() {
        guard let volume = selectedVolume,
              let root = cachedResults[volume.path] else {
            return
        }
        if let currentPath,
           currentPath != volume.path,
           let current = cachedResults[currentPath] {
            enqueueForBackgroundIndexing(current.items)
        }
        enqueueForBackgroundIndexing(root.items)
        startDirectoryPreviewingIfNeeded()
        startBackgroundIndexingIfNeeded()
    }

    func setSelected(_ item: SpaceTableItem, selected: Bool) {
        guard isDeletable(item) else { return }
        if selected {
            selectedItems[item.path] = item
        } else {
            selectedItems.removeValue(forKey: item.path)
        }
    }

    func selectCurrentItems() {
        var selected = selectedItems
        for item in items where isDeletable(item) { selected[item.path] = item }
        selectedItems = selected
    }

    func deselectAll() {
        selectedItems.removeAll()
    }

    func isDeletable(_ item: SpaceTableItem) -> Bool {
        let path = URL(fileURLWithPath: item.path).standardizedFileURL.path
        guard path != selectedVolume?.path else { return false }
        let protectedLibraryExtensions = ["photoslibrary", "photolibrary", "aplibrary"]
        if protectedLibraryExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
            return false
        }

        let protectedPrefixes = [
            "/System",
            "/Library",
            "/private",
            "/usr",
            "/bin",
            "/sbin",
            "/Applications"
        ]
        if protectedPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return false
        }
        if highRiskHomeDotPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return false
        }
        return true
    }

    func clearDeletionError() {
        deletionError = nil
    }

    func moveSelectedItemsToTrash() {
        guard !selectedItems.isEmpty, !isMovingToTrash else { return }
        guard let currentPath else { return }

        let paths = normalizedSelectedPaths()
        if paths.contains(where: {
            currentPath == $0 || currentPath.hasPrefix($0 + "/")
        }) {
            deletionError = "Go back out of a selected folder before moving it to the Trash."
            return
        }

        isMovingToTrash = true
        deletionError = nil
        cancelBackgroundIndexing()

        Task { [weak self, trashHandler] in
            guard let self else { return }
            let result = await trashHandler(paths)
            self.applyTrashResult(result)
        }
    }

    private func scan(path: String, force: Bool) {
        cancelScan()
        let generation = scanGeneration
        if !force, let cached = cachedResults[path] {
            apply(cached)
            if provisionalPaths.contains(path) { prioritizeMeasurement(at: path) }
            return
        }
        if force {
            cancelBackgroundIndexing()
            invalidateCache(atOrBelow: path)
        }
        items = []
        unreadableItemCount = 0
        state = .scanning(path: path, discoveredBytes: 0)

        scanTask = Task { [weak self, scanner] in
            guard let self else { return }
            do {
                // Descendant navigation reuses background traversal instead of
                // starting another recursive du pass over the same subtree.
                if !force, path != self.selectedVolume?.path {
                    let preview = try await scanner.previewDirectory(at: path)
                    guard !Task.isCancelled, self.scanGeneration == generation else { return }
                    // The shared index may finish while the shallow read is
                    // suspended. Accurate data always wins within a generation.
                    if let accurate = self.cachedResults[path], !self.provisionalPaths.contains(path) {
                        self.apply(accurate)
                        return
                    }
                    self.store(preview, for: path, persist: false, isProvisional: true)
                    self.apply(self.cachedResults[path] ?? preview)
                    self.prioritizeIndexing(SpaceTableItem(name: URL(fileURLWithPath: path).lastPathComponent,
                        path: path, size: 0, isDirectory: true, modificationDate: nil))
                    return
                }
                let result = try await scanner.scanDirectory(at: path) { _, bytes in
                    Task { @MainActor [self] in
                        guard !Task.isCancelled, self.scanGeneration == generation, self.currentPath == path else { return }
                        guard self.state.isScanning else { return }
                        self.state = .scanning(path: path, discoveredBytes: bytes)
                    }
                }
                guard !Task.isCancelled, self.scanGeneration == generation, self.currentPath == path else { return }
                self.store(result, for: path)
                self.apply(result)
                self.enqueueForBackgroundIndexing(result.items)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.scanGeneration == generation else { return }
                self.state = .failed(message: error.localizedDescription)
            }
        }
    }

    private func apply(_ result: SpaceTableScanResult) {
        items = result.items
        unreadableItemCount = result.unreadableItemCount
        state = .complete
    }

    private func store(
        _ result: SpaceTableScanResult,
        for path: String,
        persist: Bool = true,
        isProvisional: Bool = false
    ) {
        let isNewFolder = cachedResults[path] == nil
        if isProvisional {
            let hydrated = result.items.map { item -> SpaceTableItem in
                guard item.isDirectory, isIndexed(item.path), let child = cachedResults[item.path] else { return item }
                return .init(name: item.name, path: item.path, size: child.items.reduce(0) { $0 + $1.size },
                             isDirectory: true, modificationDate: item.modificationDate)
            }
            cachedResults[path] = .init(items: hydrated, unreadableItemCount: result.unreadableItemCount)
        } else { cachedResults[path] = result }
        if isProvisional {
            provisionalPaths.insert(path)
        } else {
            provisionalPaths.remove(path)
        }
        if isNewFolder || !isProvisional {
            indexedFolderCount = cachedResults.count - provisionalPaths.count
        }
        indexingRevision &+= 1
        if persist {
            scheduleCachePersistence()
        }
    }

    private func enqueueForBackgroundIndexing(
        _ candidates: [SpaceTableItem],
        refreshCached: Bool = false
    ) {
        let directories = candidates
            .filter(\.isDirectory)
            .sorted { $0.size < $1.size }
        for item in directories {
            guard (refreshCached
                    || cachedResults[item.path] == nil
                    || provisionalPaths.contains(item.path)),
                  queuedPaths.insert(item.path).inserted else { continue }
            indexingQueue.append(item.path)
        }
        startBackgroundIndexingIfNeeded()
    }

    private func prioritizePreview(at path: String) {
        if let index = previewQueue.firstIndex(of: path) {
            previewQueue.remove(at: index)
        } else if previewQueuedPaths.insert(path).inserted {
            // Newly queued below.
        } else {
            return
        }
        previewQueue.insert(path, at: 0)
        startDirectoryPreviewingIfNeeded()
    }

    private func startDirectoryPreviewingIfNeeded() {
        guard previewTask == nil, !previewQueue.isEmpty else { return }
        isBackgroundIndexing = true
        let generation = backgroundGeneration
        previewTask = Task(priority: .userInitiated) { [weak self, previewScanner] in
            guard let self else { return }
            await self.runDirectoryPreviews(scanner: previewScanner, generation: generation)
        }
    }

    private func runDirectoryPreviews(scanner: any SpaceTableScanning, generation: UUID) async {
        while !Task.isCancelled, backgroundGeneration == generation {
            guard let path = previewQueue.first else { break }
            previewQueue.removeFirst()
            defer { if backgroundGeneration == generation { previewQueuedPaths.remove(path) } }

            guard cachedResults[path] == nil || provisionalPaths.contains(path) else {
                continue
            }
            do {
                let result = try await scanner.previewDirectory(at: path)
                guard !Task.isCancelled, backgroundGeneration == generation else { return }
                // Completion order is independent of generation ownership:
                // never downgrade a completed index to a late shallow preview.
                guard cachedResults[path] == nil || provisionalPaths.contains(path) else { continue }
                store(result, for: path, persist: false, isProvisional: true)
                // Do not make the immediate preview compete with a full
                // traversal of the same large subtree. Once its children are
                // published, the accurate deep index can begin.
                startBackgroundIndexingIfNeeded()
            } catch is CancellationError {
                break
            } catch {
                continue
            }
        }

        guard backgroundGeneration == generation else { return }
        previewTask = nil
        isBackgroundIndexing = indexingTask != nil || interactiveTask != nil
        startBackgroundIndexingIfNeeded()
        if !previewQueue.isEmpty {
            startDirectoryPreviewingIfNeeded()
        }
    }

    private func startBackgroundIndexingIfNeeded() {
        guard indexingTask == nil, !indexingQueue.isEmpty else { return }
        if let priorityPath = indexingQueue.first,
           cachedResults[priorityPath] == nil,
           previewQueuedPaths.contains(priorityPath) {
            return
        }
        isBackgroundIndexing = true
        let generation = backgroundGeneration
        indexingTask = Task(priority: .utility) { [weak self, backgroundScanner] in
            guard let self else { return }
            await self.runBackgroundIndexing(scanner: backgroundScanner, generation: generation)
        }
    }

    private func runBackgroundIndexing(scanner: any SpaceTableScanning, generation: UUID) async {
        while !Task.isCancelled, backgroundGeneration == generation {
            guard let path = indexingQueue.first else { break }
            indexingQueue.removeFirst()

            do {
                try await scanner.indexDirectoryTree(at: path) { [weak self] batch in
                    await self?.acceptIndexBatch(batch, generation: generation)
                }
                guard !Task.isCancelled, backgroundGeneration == generation else { return }
                queuedPaths = Set(queuedPaths.filter {
                    !($0 == path || $0.hasPrefix(path + "/"))
                })
                indexingQueue.removeAll {
                    $0 == path || $0.hasPrefix(path + "/")
                }
                scheduleCachePersistence()
            } catch is CancellationError {
                break
            } catch {
                guard backgroundGeneration == generation else { return }
                queuedPaths.remove(path)
            }
        }

        guard backgroundGeneration == generation else { return }
        isBackgroundIndexing = false
        indexingTask = nil
        isBackgroundIndexing = previewTask != nil || interactiveTask != nil
        if !indexingQueue.isEmpty {
            startBackgroundIndexingIfNeeded()
        }
    }

    private func acceptIndexBatch(_ results: [String: SpaceTableScanResult], generation: UUID) {
        guard backgroundGeneration == generation else { return }
        mergeMeasuredResults(results)
    }

    private func mergeMeasuredResults(_ results: [String: SpaceTableScanResult]) {
        cachedResults.merge(results) { _, refreshed in refreshed }
        provisionalPaths.subtract(results.keys)
        // Update the row as soon as its child directory finishes, even when
        // the parent (e.g. /Users) is still being traversed. Keep remaining
        // unmeasured siblings provisional instead of turning their zeros final.
        var parents: Set<String> = []
        for (path, result) in results {
            let parent = (path as NSString).deletingLastPathComponent
            guard results[parent] == nil, let cached = cachedResults[parent],
                  let index = cached.items.firstIndex(where: { $0.path == path }) else { continue }
            var children = cached.items
            let old = children[index]
            children[index] = .init(name: old.name, path: old.path,
                size: result.items.reduce(0) { $0 + $1.size }, isDirectory: old.isDirectory,
                modificationDate: old.modificationDate)
            cachedResults[parent] = .init(items: children, unreadableItemCount: cached.unreadableItemCount)
            parents.insert(parent)
        }
        for parent in parents {
            guard let cached = cachedResults[parent] else { continue }
            cachedResults[parent] = .init(items: cached.items.sorted {
                if $0.size != $1.size { return $0.size > $1.size }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }, unreadableItemCount: cached.unreadableItemCount)
        }
        indexedFolderCount = cachedResults.count - provisionalPaths.count
        indexingRevision &+= 1
        if let path = currentPath, (results[path] != nil || parents.contains(path)),
           let current = cachedResults[path], !state.isScanning { apply(current) }
        scheduleCachePersistence()
    }

    private func acceptMeasurementPreview(_ result: SpaceTableScanResult, at path: String,
                                          background: UUID, measurement: UUID) {
        guard backgroundGeneration == background, measurementGeneration == measurement,
              !isIndexed(path) else { return }
        store(result, for: path, persist: false, isProvisional: true)
        if currentPath == path, !state.isScanning, let current = cachedResults[path] { apply(current) }
    }

    private func prioritizeMeasurement(at path: String) {
        guard !isIndexed(path) else { return }
        if let index = interactiveQueue.firstIndex(of: path) {
            interactiveQueue.remove(at: index)
        } else if !interactivePaths.insert(path).inserted { return }
        interactiveQueue.insert(path, at: 0)
        if interactiveTask != nil {
            // A later click must not wait behind an earlier /Users measure.
            // Cancel only that measurement; retain it after the new request.
            if let active = activeMeasurementPath, !interactiveQueue.contains(active) {
                interactiveQueue.append(active)
            }
            interactiveTask?.cancel()
            interactiveTask = nil
        }
        measurementGeneration = UUID()
        let measurement = measurementGeneration
        let generation = backgroundGeneration
        isBackgroundIndexing = true
        interactiveTask = Task(priority: .userInitiated) { [weak self, interactiveScanner] in
            guard let self else { return }
            while !Task.isCancelled, self.backgroundGeneration == generation,
                  self.measurementGeneration == measurement, !self.interactiveQueue.isEmpty {
                let path = self.interactiveQueue.removeFirst()
                self.activeMeasurementPath = path
                do {
                    if !self.isIndexed(path) {
                        let result = try await interactiveScanner.scanDirectory(at: path, progress: { _, _ in }) { [weak self] partial in
                            await self?.acceptMeasurementPreview(partial, at: path,
                                background: generation, measurement: measurement)
                        }
                        guard !Task.isCancelled, self.backgroundGeneration == generation,
                              self.measurementGeneration == measurement else { return }
                        // Background indexing might have finished during du.
                        if !self.isIndexed(path) { self.mergeMeasuredResults([path: result]) }
                    }
                } catch is CancellationError { break }
                catch { /* Background traversal can still resolve transient failures. */ }
                guard self.backgroundGeneration == generation, self.measurementGeneration == measurement else { return }
                self.interactivePaths.remove(path)
                self.activeMeasurementPath = nil
            }
            guard self.backgroundGeneration == generation, self.measurementGeneration == measurement else { return }
            self.interactiveTask = nil
            self.isBackgroundIndexing = self.indexingTask != nil || self.previewTask != nil
        }
    }

    private func scheduleCachePersistence(delay: Duration = .milliseconds(750)) {
        guard let volume = selectedVolume,
              cachedVolumePath == volume.path,
              cachedResults[volume.path] != nil else { return }
        persistenceTask?.cancel()
        if delay == .zero {
            let snapshot = cachedResults.filter { !provisionalPaths.contains($0.key) }
            persistenceTask = Task { [indexStore] in
                await indexStore.save(directories: snapshot, for: volume)
            }
        } else {
            persistenceTask = Task { [weak self, indexStore] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, !Task.isCancelled,
                      self.selectedVolume?.path == volume.path else { return }
                let snapshot = self.cachedResults.filter { !self.provisionalPaths.contains($0.key) }
                await indexStore.save(directories: snapshot, for: volume)
            }
        }
    }

    private func cancelBackgroundIndexing() {
        backgroundGeneration = UUID()
        indexingTask?.cancel()
        indexingTask = nil
        previewTask?.cancel()
        previewTask = nil
        interactiveTask?.cancel()
        interactiveTask = nil
        measurementGeneration = UUID()
        activeMeasurementPath = nil
        interactiveQueue.removeAll()
        interactivePaths.removeAll()
        indexingQueue.removeAll()
        queuedPaths.removeAll()
        previewQueue.removeAll()
        previewQueuedPaths.removeAll()
        isBackgroundIndexing = false
    }

    private func normalizedSelectedPaths() -> [String] {
        PathCoverage.roots(Array(selectedItems.keys))
    }

    private func applyTrashResult(_ result: SpaceTableTrashResult) {
        isMovingToTrash = false

        for path in result.removedPaths {
            selectedItems.removeValue(forKey: path)
            invalidateCache(atOrBelow: path)
        }
        removeDeletedItemsFromCachedParents(paths: result.removedPaths)

        if let currentPath, let refreshed = cachedResults[currentPath] {
            apply(refreshed)
            enqueueForBackgroundIndexing(refreshed.items)
        }
        scheduleCachePersistence()

        if !result.failures.isEmpty {
            deletionError = result.failures
                .sorted { $0.key < $1.key }
                .map { "\(URL(fileURLWithPath: $0.key).lastPathComponent): \($0.value)" }
                .joined(separator: "\n")
        }
    }

    private func invalidateCache(atOrBelow path: String) {
        let keys = cachedResults.keys.filter {
            $0 == path || $0.hasPrefix(path + "/")
        }
        for key in keys {
            cachedResults.removeValue(forKey: key)
            provisionalPaths.remove(key)
        }
        if !keys.isEmpty {
            indexedFolderCount = max(0, indexedFolderCount - keys.count)
            indexingRevision &+= 1
        }
    }

    private func removeDeletedItemsFromCachedParents(paths: [String]) {
        guard !paths.isEmpty else { return }
        for (path, result) in cachedResults {
            let filtered = result.items.filter { item in
                !paths.contains(where: {
                    item.path == $0 || item.path.hasPrefix($0 + "/")
                })
            }
            if filtered.count != result.items.count {
                cachedResults[path] = SpaceTableScanResult(
                    items: filtered,
                    unreadableItemCount: result.unreadableItemCount
                )
            }
        }
        indexingRevision &+= 1
        scheduleCachePersistence()
    }

    nonisolated private static func movePathsToTrash(
        _ paths: [String]
    ) async -> SpaceTableTrashResult {
        await Task.detached(priority: .userInitiated) {
            var removed: [String] = []
            var failures: [String: String] = [:]
            for path in paths {
                let url = URL(fileURLWithPath: path)
                var resultingURL: NSURL?
                do {
                    try FileManager.default.trashItem(
                        at: url,
                        resultingItemURL: &resultingURL
                    )
                    removed.append(path)
                } catch {
                    let nsError = error as NSError
                    if nsError.domain == NSCocoaErrorDomain,
                       nsError.code == NSFileNoSuchFileError {
                        removed.append(path)
                    } else {
                        failures[path] = error.localizedDescription
                    }
                }
            }
            return SpaceTableTrashResult(
                removedPaths: removed,
                failures: failures
            )
        }.value
    }
}
