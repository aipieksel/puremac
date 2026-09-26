import Foundation

actor PreviewOrderScanner: SpaceTableScanning {
    let root: String
    let folder: SpaceTableItem
    var pendingIndex: CheckedContinuation<[String: SpaceTableScanResult], Error>?
    var pendingPreview: CheckedContinuation<SpaceTableScanResult, Error>?
    init(root: String) { self.root = root; folder = .init(name: "folder", path: root + "/folder", size: 900, isDirectory: true, modificationDate: nil) }
    nonisolated func discoverVolumes() -> [SpaceTableVolume] { [] }
    func scanDirectory(at path: String, progress: @escaping SpaceTableScanner.ProgressHandler) async throws -> SpaceTableScanResult { .init(items: [folder], unreadableItemCount: 0) }
    func previewDirectory(at path: String) async throws -> SpaceTableScanResult { try await withCheckedThrowingContinuation { pendingPreview = $0 } }
    func indexDirectoryTree(at path: String) async throws -> [String: SpaceTableScanResult] { try await withCheckedThrowingContinuation { pendingIndex = $0 } }
    var ready: Bool { pendingIndex != nil && pendingPreview != nil }
    var indexing: Bool { pendingIndex != nil }
    func finishIndex() {
        let child = SpaceTableItem(name: "child", path: folder.path + "/child", size: 900, isDirectory: true, modificationDate: nil)
        pendingIndex?.resume(returning: [folder.path: .init(items: [child], unreadableItemCount: 0), child.path: .init(items: [], unreadableItemCount: 0)])
        pendingIndex = nil
    }
    func finishPreview() {
        let child = SpaceTableItem(name: "child", path: folder.path + "/child", size: 0, isDirectory: true, modificationDate: nil)
        pendingPreview?.resume(returning: .init(items: [child], unreadableItemCount: 0)); pendingPreview = nil
    }
}

@main struct PreviewOrderingChecks {
    @MainActor static func wait(_ condition: () async -> Bool) async throws {
        let limit = Date().addingTimeInterval(5)
        while !(await condition()) {
            guard Date() < limit else { throw NSError(domain: "Timeout", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor static func main() async throws {
        for navigate in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewRace-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let scanner = PreviewOrderScanner(root: root.path)
            let model = SpaceTableViewModel(scanner: scanner, backgroundScanner: scanner, previewScanner: scanner, indexStore: SpaceTableIndexStore(baseURL: root.appendingPathComponent("cache")))
            let folder = scanner.folder
            model.selectVolume(.init(name: "Fixture", path: root.path, totalSize: 1000, availableSize: 100))
            model.scanSelectedVolume()
            try await wait { await scanner.indexing }
            if navigate { model.open(folder) } else { model.prioritizeIndexing(folder) }
            try await wait { await scanner.ready }
            await scanner.finishIndex()
            try await wait { model.isIndexed(folder.path) }
            await scanner.finishPreview()
            try await Task.sleep(for: .milliseconds(100))
            guard model.isIndexed(folder.path), model.indexedChildren(of: folder)?.first?.size == 900,
                  !navigate || model.items.first?.size == 900 else {
                print("FAIL: late \(navigate ? "navigation" : "expansion") preview replaced a completed accurate index")
                exit(1)
            }
            model.closeVolume()
            print("PASS: late \(navigate ? "navigation" : "expansion") preview cannot replace completed index")
        }
    }
}
