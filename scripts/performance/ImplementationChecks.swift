import Foundation
import AppKit
import SwiftUI
import Combine

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    @discardableResult func add(_ key: String, _ amount: Int = 1) -> Int {
        lock.lock(); defer { lock.unlock() }
        values[key, default: 0] += amount
        return values[key]!
    }
    func get(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return values[key, default: 0] }
}

actor ControlledScanner: SpaceTableScanning {
    nonisolated func discoverVolumes() -> [SpaceTableVolume] { [] }
    var scans: [(String, SpaceTableScanner.ProgressHandler, CheckedContinuation<SpaceTableScanResult, Error>)] = []
    var indexes: [(String, CheckedContinuation<[String: SpaceTableScanResult], Error>)] = []
    var previews: [String] = []
    func scanDirectory(at path: String, progress: @escaping SpaceTableScanner.ProgressHandler) async throws -> SpaceTableScanResult {
        try await withCheckedThrowingContinuation { scans.append((path, progress, $0)) }
    }
    func previewDirectory(at path: String) async throws -> SpaceTableScanResult {
        previews.append(path)
        return .init(items: [.init(name: "child", path: path + "/child", size: 0, isDirectory: true, modificationDate: nil)], unreadableItemCount: 0)
    }
    func indexDirectoryTree(at path: String) async throws -> [String: SpaceTableScanResult] {
        try await withCheckedThrowingContinuation { indexes.append((path, $0)) }
    }
    func finishScan(_ index: Int, _ result: SpaceTableScanResult) { scans[index].2.resume(returning: result) }
    func progress(_ index: Int) { scans[index].1(1, 999999) }
    func finishIndex(_ index: Int, _ result: [String: SpaceTableScanResult]) { indexes[index].1.resume(returning: result) }
    var scanCount: Int { scans.count }
    var indexCount: Int { indexes.count }
}

@main struct ImplementationChecks {
    static let fm = FileManager.default
    @MainActor static func eventually(_ message: String, _ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()) {
            guard ContinuousClock.now < end else { fatalError(message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func check(_ value: Bool, _ message: String) { precondition(value, message) }
    static func payload(_ path: URL, count: Int = 8192) throws {
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: count).write(to: path)
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("PureMac-Implementation-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try matching()
        try await appPaths(root)
        try await sizes(root)
        try await categoryScans(root)
        try await persistence(root)
        try await lifecycle(root)
        try await appLoading()
        try await selections()
        try await rowsAndRendering(root)
        try await samplingAndIcons()
        try await transactions(root)
        print("PASS: all implementation fixtures")
    }

    static func matching() throws {
        let cases = [[], ["a", "aba", "ba", "bc"], ["é", "e\u{301}", "👩‍💻", "K"], ["", "a"], ["a", "aa", "aaa", "baaaa"]]
        let candidates = ["", "a", "ababa", "bbb", "bc", "cafe\u{301}", "é", "K", "👩‍💻", "é .́-️_"] + (0..<5000).map { "org.vendor.\($0).abc" }
        for patterns in cases {
            let index = AppOwnershipIndex(patterns: patterns)
            for candidate in candidates {
                check(index.containsMatch(in: candidate) == patterns.contains { candidate.contains($0) }, "ownership mismatch \(patterns) / \(candidate)")
            }
        }
        check(PathCoverage.roots(["/foo/bar", "/foo-bar", "/foo", "/foo/../foo"]) == ["/foo", "/foo-bar"], "component prefix")
        check(PathCoverage.roots(["/", "/foo", "/foo-bar"]) == ["/"], "root coverage")
        print("PASS: substring differential parity, Unicode, empty patterns and path coverage")
    }

    @MainActor static func appPaths(_ root: URL) async throws {
        let directory = root.appendingPathComponent("matching")
        try payload(directory.appendingPathComponent("com.fixture.uniqueabc/data"))
        try payload(directory.appendingPathComponent("unrelated/data"))
        let app = directory.appendingPathComponent("UniqueABC.app")
        let locations = Locations()
        locations.appSearch.paths = [directory.path, directory.path]
        let info = AppPathFinder.AppInfo(appName: "UniqueABC", bundleIdentifier: "com.fixture.uniqueabc", path: app, entitlements: nil, teamIdentifier: nil)
        let counter = Counter()
        let finder = AppPathFinder(appInfo: info, locations: locations, enumerate: { path in
            counter.add(path)
            return try? fm.contentsOfDirectory(atPath: path)
        }, containersURL: nil)
        let result = await withCheckedContinuation { continuation in finder.findPathsAsync { continuation.resume(returning: $0) } }
        check(result.contains(directory.appendingPathComponent("com.fixture.uniqueabc")), "matched files missing")
        check(!result.contains(directory.appendingPathComponent("unrelated")), "unrelated file matched")
        check(counter.get(directory.path) == 1, "duplicate root enumeration")
        let stopped = AppPathFinder(appInfo: info, locations: locations, enumerate: { path in counter.add("canceled-enumeration"); return [] }, containersURL: nil)
        stopped.cancel()
        stopped.findPathsAsync { _ in counter.add("canceled-callback") }
        try await Task.sleep(for: .milliseconds(30))
        check(counter.get("canceled-enumeration") == 0 && counter.get("canceled-callback") == 0, "finder continued after cancel")
        let running = AppPathFinder(appInfo: info, locations: locations, enumerate: { _ in
            counter.add("inflight-start")
            Thread.sleep(forTimeInterval: 0.05)
            return ["com.fixture.uniqueabc"]
        }, containersURL: nil)
        running.findPathsAsync { _ in counter.add("inflight-callback") }
        try await eventually("finder did not start") { counter.get("inflight-start") == 1 }
        running.cancel()
        try await Task.sleep(for: .milliseconds(90))
        check(counter.get("inflight-start") == 1 && counter.get("inflight-callback") == 0, "in-flight finder continued after cancellation")
        print("PASS: app matching fixture, duplicate-root enumeration and pre/in-flight cancellation")
    }

    @MainActor static func sizes(_ root: URL) async throws {
        let counter = Counter()
        let cache = FileSizeCache { url in
            counter.add(url.lastPathComponent)
            return 42
        }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        let generation = UUID()
        await cache.update([a,b], generation: generation)
        await cache.update([a], generation: generation)
        check(counter.get("a") == 1 && cache.sizes == [a:42], "survivor cache")
        await cache.update([a], generation: UUID())
        check(counter.get("a") == 2, "generation invalidation")
        let slow = FileSizeCache { _ in
            counter.add("started")
            while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.002) }
            counter.add("canceled")
            return 9
        }
        let task = Task { await slow.update([a,b], generation: UUID()) }
        try await eventually("size worker did not start") { counter.get("started") == 1 }
        task.cancel(); await task.value
        check(counter.get("canceled") == 1 && slow.sizes.isEmpty, "size cancellation publication")
        let tree = root.appendingPathComponent("size-tree")
        try payload(tree.appendingPathComponent("payload"))
        try fm.createSymbolicLink(at: tree.appendingPathComponent("link"), withDestinationURL: root)
        check((FileSizeCalculator.size(of: tree) ?? 0) > 0, "real allocated size")
        print("PASS: shared sizing reuse, generation invalidation, worker cancellation and real metadata")
    }

    @MainActor static func categoryScans(_ root: URL) async throws {
        let counter = Counter()
        await ScanEngine.scanCategories([.systemJunk, .userCache, .trashBins, .userCache], scan: { category in
            let active = counter.add("active")
            if active > 2 { counter.add("overflow") }
            if active == 2 { counter.add("parallel") }
            try? await Task.sleep(for: .milliseconds(40))
            counter.add("active", -1)
            return CategoryResult(category: category, items: [], totalSize: 0)
        }, onResult: { _, completed, total in
            counter.add("results")
            check(completed <= total && total == 3, "category progress")
        })
        check(counter.get("overflow") == 0 && counter.get("parallel") > 0 && counter.get("results") == 3, "bounded categories")
        let cache = root.appendingPathComponent("cache")
        let owned = cache.appendingPathComponent("vendor/node")
        try payload(owned.appendingPathComponent("data"))
        try payload(cache.appendingPathComponent("vendor/unrelated/data"))
        try payload(cache.appendingPathComponent("peer/data"))
        try fm.createSymbolicLink(at: cache.appendingPathComponent("link"), withDestinationURL: owned)
        let result = await ScanEngine().scanDirectory(path: cache.path, category: .userCache, recursive: false, maxDepth: 1, excluding: [owned.path])
        check(Set(result.map(\.path)) == [cache.appendingPathComponent("vendor/unrelated").path, cache.appendingPathComponent("peer").path], "overlap lost siblings or included symlink")
        let limiter = SpaceTableScanner.ProcessLimiter(limit: 1)
        try await limiter.acquire()
        let waiting = Task { try await limiter.acquire() }
        try await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        do { try await waiting.value; fatalError("canceled waiter acquired") } catch is CancellationError {}
        await limiter.release()
        try await limiter.acquire(); await limiter.release()
        print("PASS: bounded categories, exact ownership coverage and canceled queued process permit")
    }

    @MainActor static func persistence(_ root: URL) async throws {
        let volume = SpaceTableVolume(name: "Fixture", path: root.path, totalSize: 1000, availableSize: 500)
        let cache = root.appendingPathComponent("index-cache")
        let store = SpaceTableIndexStore(baseURL: cache)
        let empty = SpaceTableScanResult(items: [], unreadableItemCount: 0)
        var results = [root.path: empty, root.path + "/a": empty]
        await store.save(directories: results, for: volume)
        check(await store.writtenChunkCount == 2, "initial chunks")
        await store.save(directories: results, for: volume)
        check(await store.writtenChunkCount == 2, "unchanged chunks rewritten")
        results[root.path + "/a"] = .init(items: [], unreadableItemCount: 1)
        await store.save(directories: results, for: volume)
        check(await store.writtenChunkCount == 3, "incremental chunks")
        check(await SpaceTableIndexStore(baseURL: cache).load(for: volume) == results, "restore")
        check(await SpaceTableIndexStore(baseURL: cache, maximumAge: -1).load(for: volume) == nil, "age")
        let changed = SpaceTableVolume(name: "Fixture", path: root.path, totalSize: 1001, availableSize: 500)
        check(await store.load(for: changed) == nil, "volume identity")
        enum Injected: Error { case write }
        let failing = SpaceTableIndexStore(baseURL: cache, beforeCommit: { throw Injected.write })
        await failing.save(directories: [root.path: empty], for: volume)
        check(await SpaceTableIndexStore(baseURL: cache).load(for: volume) == results, "failed save replaced manifest")
        let directory = try fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first!
        let chunk = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent != "manifest.plist" }!
        try Data("corrupt".utf8).write(to: chunk)
        check(await SpaceTableIndexStore(baseURL: cache).load(for: volume) == nil, "corrupt chunk accepted")
        print("PASS: incremental persistence, restoration, age/volume validation, corrupt chunk refusal")
    }

    @MainActor static func lifecycle(_ root: URL) async throws {
        let scanner = ControlledScanner()
        let store = SpaceTableIndexStore(baseURL: root.appendingPathComponent("lifecycle-cache"))
        let model = SpaceTableViewModel(scanner: scanner, backgroundScanner: scanner, previewScanner: scanner, indexStore: store)
        let volume = SpaceTableVolume(name: "A", path: root.path + "/A", totalSize: 1000, availableSize: 500)
        let other = SpaceTableVolume(name: "B", path: root.path + "/B", totalSize: 1000, availableSize: 500)
        let a = SpaceTableItem(name: "sub", path: volume.path + "/sub", size: 42, isDirectory: true, modificationDate: nil)
        let b = SpaceTableItem(name: "sub", path: other.path + "/sub", size: 64, isDirectory: true, modificationDate: nil)
        model.selectVolume(volume); model.scanSelectedVolume()
        try await eventually("first scan") { await scanner.scanCount == 1 }
        model.cancelScan(); await scanner.progress(0)
        try await Task.sleep(for: .milliseconds(20))
        check(!model.state.isScanning, "late canceled progress")
        model.scanSelectedVolume()
        try await eventually("second scan") { await scanner.scanCount == 2 }
        await scanner.finishScan(0, .init(items: [], unreadableItemCount: 0))
        await scanner.finishScan(1, .init(items: [a], unreadableItemCount: 0))
        try await eventually("first index") { await scanner.indexCount == 1 }
        await scanner.progress(1)
        try await Task.sleep(for: .milliseconds(20))
        check(!model.state.isScanning && model.items == [a], "late completed progress")
        model.prioritizeIndexing(a)
        try await eventually("shallow preview") { !(await scanner.previews).isEmpty }
        check(model.indexedChildren(of: a)?.first.map { model.isSizePending($0) } == true && !model.isIndexed(a.path), "preview marked complete")
        // Let the normal debounce settle while the deep index is held.
        try await Task.sleep(for: .milliseconds(850))
        let partialCache = await store.load(for: volume)
        check(partialCache?[volume.path] != nil && partialCache?[a.path] == nil, "provisional preview persisted as complete")
        model.selectVolume(other); model.scanSelectedVolume()
        try await eventually("third scan") { await scanner.scanCount == 3 }
        await scanner.finishScan(2, .init(items: [b], unreadableItemCount: 0))
        try await eventually("second index") { await scanner.indexCount == 2 }
        await scanner.finishIndex(0, [a.path: .init(items: [], unreadableItemCount: 0)])
        try await Task.sleep(for: .milliseconds(20))
        check(model.isBackgroundIndexing && model.items == [b], "old worker cleared new ownership")
        await scanner.finishIndex(1, [b.path: .init(items: [], unreadableItemCount: 0)])
        try await eventually("index completion") { !model.isBackgroundIndexing }
        check(model.isIndexed(b.path), "new result missing")
        check(await scanner.scanCount == 3, "expansion started recursive scan")
        model.closeVolume()
        print("PASS: controlled cancellation, stale progress, shallow expansion and cross-volume worker ownership")
    }

    @MainActor static func appLoading() async throws {
        let count = Counter()
        let icon = NSImage(size: NSSize(width: 32, height: 32))
        let apps = (0..<4).map { InstalledApp(id: UUID(), appName: "App\($0)", bundleIdentifier: "fixture.\($0)", path: URL(fileURLWithPath: "/fixture/App\($0).app"), icon: icon, size: 0, isSizePending: true) }
        let state = AppState(performStartupTasks: false, appDiscovery: { count.add("discover"); return apps }, appMeasurement: { app in
            let active = count.add("active")
            if active > 2 { count.add("overflow") }
            Thread.sleep(forTimeInterval: 0.15)
            count.add("active", -1)
            return InstalledApp(id: app.id, appName: app.appName, bundleIdentifier: app.bundleIdentifier, path: app.path, icon: app.icon, size: 100)
        })
        state.loadInstalledApps(); state.loadInstalledApps()
        try await eventually("metadata publication") { state.installedApps.count == 4 }
        check(state.installedApps.allSatisfy(\.isSizePending) && !state.isLoadingApps, "metadata waited for measurement")
        try await eventually("measurements") { state.installedApps.allSatisfy { !$0.isSizePending } }
        check(count.get("discover") == 1 && count.get("overflow") == 0, "loading coalescing or concurrency")
        let ids = state.installedApps.map(\.id)
        state.loadInstalledApps()
        try await eventually("refresh") { count.get("discover") == 2 }
        check(state.installedApps.map(\.id) == ids, "identity changed")
        state.cancelAppLoading()
        state.cancelOrphanScan()
        print("PASS: metadata-first loading, bounded measurement, duplicate coalescing and stable identities")
    }

    @MainActor static func selections() async throws {
        let state = AppState(performStartupTasks: false)
        let items = (0..<200).map { CleanableItem(name: "item\($0)", path: "/fixture/\($0)", size: 10, category: .userCache, isSelected: $0 % 2 == 0, lastModified: nil) }
        state.categoryResults[.userCache] = .init(category: .userCache, items: items, totalSize: 2000)
        var publications = 0
        let subscription = state.objectWillChange.sink { publications += 1 }
        state.selectAllInCategory(.userCache)
        check(state.totalSelectedSize == 2000 && publications <= 2, "select all notifications or semantics")
        publications = 0
        state.deselectAllInCategory(.userCache)
        check(state.totalSelectedSize == 0 && publications <= 2, "deselect all notifications or semantics")
        withExtendedLifetime(subscription) {}
        print("PASS: selection semantics and constant publication count for 200 items")
    }

    @MainActor static func rowsAndRendering(_ root: URL) async throws {
        let parent = SpaceTableItem(name: "parent", path: root.path + "/parent", size: 50, isDirectory: true, modificationDate: nil)
        let child = SpaceTableItem(name: "child", path: parent.path + "/child", size: 20, isDirectory: false, modificationDate: nil)
        let sibling = SpaceTableItem(name: "sibling", path: root.path + "/sibling", size: 10, isDirectory: false, modificationDate: nil)
        var cache = SpaceTableRowCache()
        let key = SpaceTableRowCache.Key(items: [sibling, parent], revision: 1, expanded: [parent.path], column: .size, ascending: false)
        cache.update(key) { _ in [child] }
        check(cache.rows.map { $0.item.path } == [parent.path, child.path, sibling.path], "flatten order")
        check(cache.rows.map(\.depth) == [0,1,0], "flatten depth")
        cache.update(key) { _ in fatalError("unchanged structure rebuilt") }
        check(cache.rebuildCount == 1, "selection-only cache rebuild")
        let items = (0..<40).map { CleanableItem(name: "name\($0 % 3)", path: "/fixture/\($0)", size: Int64($0 % 5), category: .userCache, isSelected: true, lastModified: nil) }
        for query in ["", "name1", "FIXTURE/2", "absent"] {
            for descending in [true, false] {
                let original = items.sorted { descending ? $0.size > $1.size : $0.size < $1.size }.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
                check(CategoryDetailView.displayItems(items, search: query, descending: descending).map(\.id) == original.map(\.id), "filter/sort tie parity")
            }
        }
        // Render isolated, side-effect-free native SwiftUI components. This
        // does not open a window, run startup scans or modify personal apps.
        let view = NSHostingView(rootView: ScanningGauge(progress: 0.5).environment(\.scenePhase, .inactive).frame(width: 180, height: 180))
        view.frame = NSRect(x: 0, y: 0, width: 180, height: 180)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("native bitmap unavailable") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        check(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "native component rendering")
        print("PASS: cached row flattening, filter/sort tie parity and native NSHostingView component rendering")
    }

    @MainActor static func samplingAndIcons() async throws {
        check(AnimationActivity.minimumInterval >= 1.0 / 30, "animation cadence")
        check(AnimationActivity.isActive(scene: .active, reduceMotion: false), "active animation")
        check(!AnimationActivity.isActive(scene: .inactive, reduceMotion: false), "inactive animation")
        check(!AnimationActivity.isActive(scene: .active, reduceMotion: true), "reduced motion")
        check(!AnimationActivity.isActive(scene: .active, reduceMotion: false, enabled: false), "disabled animation")
        let count = Counter()
        var date = Date()
        let monitor = SystemMonitor(now: { date }, diskSampler: { count.add("disk"); return (100, 40) })
        monitor.sampleDisk(); monitor.sampleDisk()
        try await eventually("disk sample") { monitor.diskTotal == 100 }
        monitor.sampleDisk()
        check(count.get("disk") == 1, "disk cadence")
        date = date.addingTimeInterval(31)
        monitor.sampleDisk()
        try await eventually("second sample") { count.get("disk") == 2 }
        monitor.stop()
        var calls = 0
        let cache = FileIconCache { _ in calls += 1; try? await Task.sleep(for: .milliseconds(30)); return NSImage(size: .init(width: 16, height: 16)) }
        async let first = cache.icon(for: "fixture")
        async let second = cache.icon(for: "fixture")
        _ = await (first, second)
        _ = await cache.icon(for: "fixture")
        check(calls == 1, "icons not coalesced/cached")
        print("PASS: disk sampling cadence and icon request coalescing/cache")
    }

    @MainActor static func transactions(_ root: URL) async throws {
        for mode in ["success", "sign", "verify", "restricted"] {
            let app = root.appendingPathComponent("\(mode).app")
            let resources = app.appendingPathComponent("Contents/Resources")
            for lang in ["zz", "xx", "en", "Base", "dev"] { try payload(resources.appendingPathComponent("\(lang).lproj/strings")) }
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleDevelopmentRegion": "dev"], format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            let count = Counter()
            let thinner = BinaryThinner { executable, args in
                if args.contains("--entitlements") { return (0, mode == "restricted" ? "com.apple.developer.fixture" : "", "") }
                if args.contains("--sign") { count.add("sign"); return (mode == "sign" ? 1 : 0, "", "injected sign") }
                if args.contains("--verify") { count.add("verify"); return (mode == "verify" ? 1 : 0, "", "injected verify") }
                return (0, "", "")
            }
            let engine = CleaningEngine(binaryThinner: thinner, appRoots: [root.path])
            let items = ["zz", "xx", "en", "Base", "dev"].map { lang in CleanableItem(name: lang, path: resources.appendingPathComponent("\(lang).lproj").path, size: 8192, category: .languageFiles, isSelected: true, lastModified: nil) }
            let result = await engine.cleanItems(items) { _ in }
            check(result.errors.count == (mode == "success" ? 3 : 5), "per-item outcome \(mode): \(result.errors)")
            check(result.itemsCleaned == (mode == "success" ? 2 : 0), "transaction outcome")
            check(count.get("sign") == (mode == "restricted" ? 0 : 1), "more than one staged transaction")
            for lang in ["zz", "xx", "en", "Base", "dev"] {
                let shouldExist = mode != "success" || !["zz", "xx"].contains(lang)
                check(fm.fileExists(atPath: resources.appendingPathComponent("\(lang).lproj/strings").path) == shouldExist, "original altered on failed/refused transaction")
            }
            check(!(try fm.contentsOfDirectory(atPath: root.path)).contains { $0.contains("puremac-staging") || $0.contains("puremac-old") }, "staging residue")
        }
        let app = root.appendingPathComponent("mixed.app")
        let binary = app.appendingPathComponent("Contents/MacOS/test")
        let language = app.appendingPathComponent("Contents/Resources/zz.lproj")
        try payload(binary, count: 10000)
        try payload(language.appendingPathComponent("strings"))
        let counter = Counter()
        let thinner = BinaryThinner { executable, args in
            if executable.hasSuffix("lipo") {
                try! Data(repeating: 1, count: 2000).write(to: URL(fileURLWithPath: args.last!))
            }
            if args.contains("--sign") { counter.add("sign") }
            return (0, "", "")
        }
        let finding = UniversalBinaryFinding(appPath: app.path, appName: "mixed", executablePath: binary.path,
            nativeArch: "arm64", removableArchs: ["x86_64"], reclaimableBytes: 8000, appStore: false,
            fatBinaries: [.init(path: binary.path, removableArchs: ["x86_64"], reclaimableBytes: 8000)])
        let mixed = await thinner.modify(appPath: app.path, localizations: [language.path], finding: finding)
        check(try mixed.get() == 8000 && counter.get("sign") == 1, "mixed modifications repeated staging")
        let binaryData = try Data(contentsOf: binary)
        check(!fm.fileExists(atPath: language.path) && binaryData.count == 2000, "mixed result")
        let rejected = await thinner.modify(appPath: app.path, localizations: [root.path + "/escape.lproj"], finding: nil)
        if case .success = rejected { fatalError("outside path accepted") }
        check(counter.get("sign") == 1, "rejected batch reached signing")
        print("PASS: one transaction for multiple languages plus thinning; keep sets, development region, restricted entitlements, sign/verify rollback and per-item results")
    }
}
