import Foundation

actor BlockedBackground: SpaceTableScanning {
    var active: String?
    var release: CheckedContinuation<Void, Never>?
    nonisolated func discoverVolumes() -> [SpaceTableVolume] { [] }
    func scanDirectory(at path: String, progress: @escaping SpaceTableScanner.ProgressHandler) async throws -> SpaceTableScanResult {
        try await SpaceTableScanner().scanDirectory(at: path, progress: progress)
    }
    func previewDirectory(at path: String) async throws -> SpaceTableScanResult {
        try await SpaceTableScanner().previewDirectory(at: path)
    }
    func indexDirectoryTree(at path: String) async throws -> [String: SpaceTableScanResult] {
        active = path
        await withCheckedContinuation { release = $0 }
        try Task.checkCancellation()
        return [:]
    }
    func finish() { release?.resume(); release = nil }
}

actor DelayedMeasurement: SpaceTableScanning {
    let delayedPath: String
    var started = false
    init(path: String) { delayedPath = path }
    nonisolated func discoverVolumes() -> [SpaceTableVolume] { [] }
    func scanDirectory(at path: String, progress: @escaping SpaceTableScanner.ProgressHandler) async throws -> SpaceTableScanResult {
        if (path as NSString).lastPathComponent == (delayedPath as NSString).lastPathComponent {
            started = true
            try await Task.sleep(for: .seconds(30))
        }
        return try await SpaceTableScanner().scanDirectory(at: path, progress: progress)
    }
    func previewDirectory(at path: String) async throws -> SpaceTableScanResult { try await SpaceTableScanner().previewDirectory(at: path) }
    func indexDirectoryTree(at path: String) async throws -> [String: SpaceTableScanResult] { [:] }
}

actor PartialRecorder {
    var totals: [Int64] = []
    func accept(_ result: SpaceTableScanResult) { totals.append(result.items.reduce(0) { $0 + $1.size }) }
    func verified() -> Bool { totals.count == 2 && totals[0] > 0 && totals[0] < totals[1] }
}

actor BatchRecorder {
    var results: [String: SpaceTableScanResult] = [:]
    var publishedBeforeRoot = false
    var batchCount = 0
    func accept(_ batch: [String: SpaceTableScanResult], root: String) {
        if batch[root] == nil { publishedBeforeRoot = true }
        batchCount += 1
        results.merge(batch) { _, new in new }
    }
    func verify(root: String) -> Bool {
        publishedBeforeRoot && batchCount > 1 && results.count == 301 && results[root]?.items.count == 300
    }
}

@main struct SpaceTableLatencyChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("PureMac-Latency-\(UUID())")
        defer { try? fm.removeItem(at: base) }
        let disk = base.appendingPathComponent("disk")
        for name in ["one", "two"] {
            let child = disk.appendingPathComponent(name + "/child")
            try fm.createDirectory(at: child, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 8192).write(to: child.appendingPathComponent("payload"))
        }
        let blocked = BlockedBackground()
        let model = SpaceTableViewModel(backgroundScanner: blocked, indexStore: SpaceTableIndexStore(baseURL: base.appendingPathComponent("cache")))
        model.selectVolume(.init(name: "Fixture", path: disk.path, totalSize: 100000, availableSize: 0))
        model.scanSelectedVolume()
        let deadline = Date().addingTimeInterval(5)
        while await blocked.active == nil {
            if Date() > deadline { fatalError("Background did not start") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let active = await blocked.active!
        let opened = model.items.first { $0.path != active }!
        let start = Date()
        model.prioritizeIndexing(opened)
        while !model.isIndexed(opened.path), Date().timeIntervalSince(start) < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let passed = model.isIndexed(opened.path) && (model.indexedChildren(of: opened)?.first?.size ?? 0) > 0
        let elapsed = Date().timeIntervalSince(start)
        model.closeVolume()
        await blocked.finish()
        print("\(passed ? "PASS" : "FAIL"): expanded sibling measured while background is blocked; seconds=\(elapsed)")
        if !passed { exit(1) }
        try await Task.sleep(for: .milliseconds(100))
        guard model.items.isEmpty, model.selectedVolume == nil, !model.isBackgroundIndexing else { fatalError("Canceled worker republished state") }
        print("PASS: closing volume cancels interactive work without stale publication")
        let delayed = DelayedMeasurement(path: disk.appendingPathComponent("one").path)
        let blockedAgain = BlockedBackground()
        let nextModel = SpaceTableViewModel(backgroundScanner: blockedAgain, interactiveScanner: delayed,
            indexStore: SpaceTableIndexStore(baseURL: base.appendingPathComponent("cache2")))
        nextModel.selectVolume(.init(name: "Fixture", path: disk.path, totalSize: 100000, availableSize: 0))
        nextModel.scanSelectedVolume()
        let secondDeadline = Date().addingTimeInterval(5)
        while await blockedAgain.active == nil {
            guard Date() < secondDeadline else { fatalError("Second background did not start") }
            try await Task.sleep(for: .milliseconds(10))
        }
        nextModel.prioritizeIndexing(nextModel.items.first { $0.name == "one" }!)
        let measurementDeadline = Date().addingTimeInterval(5)
        while !(await delayed.started) {
            guard Date() < measurementDeadline else { fatalError("First interactive measurement did not start") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let latest = nextModel.items.first { $0.name == "two" }!
        let latestStart = Date()
        nextModel.prioritizeIndexing(latest)
        while !nextModel.isIndexed(latest.path), Date().timeIntervalSince(latestStart) < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard nextModel.isIndexed(latest.path) else { fatalError("Latest expansion waited behind earlier measurement") }
        nextModel.closeVolume()
        await blockedAgain.finish()
        print("PASS: latest expansion preempts earlier slow measurement")
        let streamingRoot = base.appendingPathComponent("streaming")
        for index in 0..<300 {
            try fm.createDirectory(at: streamingRoot.appendingPathComponent("child-\(index)"), withIntermediateDirectories: true)
        }
        let recorder = BatchRecorder()
        try await SpaceTableScanner().indexDirectoryTree(at: streamingRoot.path) {
            await recorder.accept($0, root: streamingRoot.path)
        }
        guard await recorder.verify(root: streamingRoot.path) else { fatalError("Subtree results were not published incrementally") }
        let missing = try await SpaceTableScanner().indexDirectoryTree(at: base.appendingPathComponent("missing").path)
        guard missing.values.first?.unreadableItemCount == 1 else { fatalError("Missing directory was reported as readable") }
        print("PASS: completed folders stream before root completion; unreadable root stays explicit")
        let partials = PartialRecorder()
        _ = try await SpaceTableScanner(maxConcurrentWorkers: 2).scanDirectory(at: disk.path, progress: { _, _ in }) {
            await partials.accept($0)
        }
        guard await partials.verified() else { fatalError("Measured child totals did not arrive independently") }
        print("PASS: direct-child sizes publish separately before the full measurement finishes")
        let systemPreview = try await SpaceTableScanner().previewDirectory(at: "/System")
        guard !systemPreview.items.contains(where: { $0.path == "/System/Volumes" }) else {
            fatalError("Expanding System would rescan the mounted Data volume")
        }
        print("PASS: System expansion excludes its mounted-volume mirror")
    }
}
