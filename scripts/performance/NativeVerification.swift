import AppKit
import SwiftUI
import Sparkle

@main struct NativeVerification {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PUREMAC_VERIFY_OUTPUT"]!)
            do {
                try await verify(output)
                try "PASS: native view rendering, real signing/thinning and Sparkle runtime loading\n".write(to: output.appendingPathComponent("native-result.txt"), atomically: true, encoding: .utf8)
                exit(0)
            } catch {
                try? "FAIL: \(error)\n".write(to: output.appendingPathComponent("native-result.txt"), atomically: true, encoding: .utf8)
                exit(1)
            }
        }
        app.run()
    }
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func command(_ executable: String, _ args: [String]) throws -> Subprocess.Output {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
        let result = try Subprocess.run(process, timeout: 60)
        try require(result.status == 0, "\(executable): \(String(decoding: result.stderr, as: UTF8.self))")
        return result
    }
    @MainActor static func verify(_ output: URL) async throws {
        let fm = FileManager.default
        let fixture = output.appendingPathComponent("fixtures", isDirectory: true)
        let appURL = fixture.appendingPathComponent("Transaction.app")
        let executable = appURL.appendingPathComponent("Contents/MacOS/fixture")
        let languages = ["zz", "xx"].map { appURL.appendingPathComponent("Contents/Resources/\($0).lproj") }
        _ = try command(executable.path, [])
        try require(UniversalBinaryScanner().finding(forAppAt: appURL.path) != nil, "universal fixture not detected")
        let before = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path])
        _ = before
        let items = languages.map { CleanableItem(name: $0.lastPathComponent, path: $0.path, size: 4096, category: .languageFiles, isSelected: true, lastModified: nil) } + [CleanableItem(name: "Transaction", path: appURL.path, size: 1, category: .universalBinaries, isSelected: true, lastModified: nil)]
        let outcome = await CleaningEngine(appRoots: [fixture.path]).cleanItems(items) { _ in }
        try require(outcome.errors.isEmpty && outcome.itemsCleaned == 3, "real transaction failed: \(outcome.errors)")
        try require(languages.allSatisfy { !fm.fileExists(atPath: $0.path) }, "languages remain")
        try require(fm.fileExists(atPath: appURL.appendingPathComponent("Contents/Resources/en.lproj/strings").path), "English removed")
        try require(UniversalBinaryScanner().finding(forAppAt: appURL.path) == nil, "foreign architecture remains")
        _ = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path])
        _ = try command(executable.path, [])
        try "Real staged cleanup: 3 items, \(outcome.freedSpace) bytes reported; signed executable runs before and after.\n".write(to: output.appendingPathComponent("transaction-result.txt"), atomically: true, encoding: .utf8)

        // Force the real dependency branch to instantiate without starting an updater.
        let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        withExtendedLifetime(updater) {}
        let state = AppState(performStartupTasks: false)
        let theme = ThemeManager()
        state.diskInfo = DiskInfo(totalSpace: 500_000_000_000, freeSpace: 200_000_000_000, usedSpace: 300_000_000_000, purgeableSpace: 0)
        let sample = InstalledApp(id: UUID(), appName: "Verification App", bundleIdentifier: "fixture.verification", path: appURL, icon: NSWorkspace.shared.icon(forFile: appURL.path), size: 16384)
        state.installedApps = [sample]
        state.discoveredFiles = [appURL]
        state.selectedFiles = [appURL]
        state.orphanedFiles = [fixture.appendingPathComponent("orphan-cache")]
        try fm.createDirectory(at: state.orphanedFiles[0], withIntermediateDirectories: true)
        try Data(repeating: 0x33, count: 32768).write(to: state.orphanedFiles[0].appendingPathComponent("payload"))
        let cacheItem = CleanableItem(name: "Fixture cache", path: state.orphanedFiles[0].path, size: 32768, category: .userCache, isSelected: true, lastModified: Date())
        state.categoryResults[.userCache] = .init(category: .userCache, items: [cacheItem], totalSize: 32768)
        state.totalJunkSize = 32768
        let scanner = FixtureVolumeScanner(root: fixture.path)
        let model = SpaceTableViewModel(scanner: scanner, backgroundScanner: scanner, previewScanner: scanner, indexStore: SpaceTableIndexStore(baseURL: output.appendingPathComponent("index")))
        model.selectVolume(scanner.volume)
        model.scanSelectedVolume()
        let deadline = Date().addingTimeInterval(20)
        while model.state.isScanning || model.isBackgroundIndexing {
            try require(Date() < deadline, "fixture scan timeout")
            try await Task.sleep(for: .milliseconds(25))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 960), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "PureMac Performance Verification"
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let screens: [(String, AnyView)] = [
            ("dashboard", AnyView(MainWindow())),
            ("apps", AnyView(AppListView())),
            ("related-files", AnyView(AppFilesView(app: sample))),
            ("orphans", AnyView(OrphanListView())),
            ("category", AnyView(CategoryDetailView(category: .userCache))),
            ("space-table", AnyView(SpaceTableView(viewModel: model)))
        ]
        for (name, view) in screens {
            let controller = NSHostingController(rootView: view.environmentObject(state).environmentObject(theme).environment(\.scenePhase, .active).environment(\.colorScheme, .light).frame(width: 1280, height: 960).background(Color(nsColor: .windowBackgroundColor)))
            window.contentViewController = controller
            let host = controller.view
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(1500))
            host.layoutSubtreeIfNeeded()
            guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure(message: "no bitmap: \(name)") }
            host.cacheDisplay(in: host.bounds, to: image)
            guard let png = image.representation(using: .png, properties: [:]) else { throw Failure(message: "no PNG: \(name)") }
            try png.write(to: output.appendingPathComponent(name + ".png"))
            try require(image.pixelsWide >= 1200 && image.pixelsHigh >= 900, "invalid view dimensions: \(name)")
        }
        try require(state.appFileSizes.sizes[appURL] != nil, "related-file view never received background size")
        try require(state.orphanSizes.sizes[state.orphanedFiles[0]] != nil, "orphan view never received background size")
        model.closeVolume()
    }
}

private actor FixtureVolumeScanner: SpaceTableScanning {
    nonisolated let volume: SpaceTableVolume
    private let scanner = SpaceTableScanner()
    init(root: String) { volume = .init(name: "Fixture Volume", path: root, totalSize: 1_000_000, availableSize: 500_000) }
    nonisolated func discoverVolumes() -> [SpaceTableVolume] { [volume] }
    func scanDirectory(at path: String, progress: @escaping SpaceTableScanner.ProgressHandler) async throws -> SpaceTableScanResult { try await scanner.scanDirectory(at: path, progress: progress) }
    func previewDirectory(at path: String) async throws -> SpaceTableScanResult { try await scanner.previewDirectory(at: path) }
    func indexDirectoryTree(at path: String) async throws -> [String: SpaceTableScanResult] { try await scanner.indexDirectoryTree(at: path) }
}
