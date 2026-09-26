import Foundation
import Combine

@main struct IndexPublicationBenchmark {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("PureMac-Publication-\(UUID())")
        let disk = root.appendingPathComponent("disk")
        let subtree = disk.appendingPathComponent("subtree")
        try fm.createDirectory(at: subtree, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for i in 0..<500 {
            try fm.createDirectory(at: subtree.appendingPathComponent("child-\(i)"), withIntermediateDirectories: true)
        }
        try Data(repeating: 0x5A, count: 32768)
            .write(to: subtree.appendingPathComponent("child-0/payload"))
        let store = SpaceTableIndexStore(baseURL: root.appendingPathComponent("cache"))
        let model = SpaceTableViewModel(indexStore: store)
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }
        let volume = SpaceTableVolume(name: "Fixture", path: disk.path, totalSize: 1000000, availableSize: 500000)
        model.selectVolume(volume)
        publications = 0
        model.scanSelectedVolume()
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while model.state.isScanning || model.isBackgroundIndexing {
            guard ContinuousClock.now < deadline else { fatalError("Index did not finish") }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard model.indexedFolderCount == 502 else { print("FAIL: count \(model.indexedFolderCount); state \(model.state); items \(model.items.map(\.path))"); exit(1) }
        let indexedSubtree = URL(fileURLWithPath: model.items.first { $0.name == "subtree" }!.path)
        for i in 0..<500 {
            let path = indexedSubtree.appendingPathComponent("child-\(i)").path
            guard model.isIndexed(path) else { print("FAIL: missing \(path); root items \(model.items.map(\.path))"); exit(1) }
        }
        print("PASS: all 502 directories indexed; objectWillChange publications: \(publications)")
        precondition(model.scannedSize == model.items.reduce(0) { $0 + $1.size })
        precondition(model.scannedSize > 0, "Non-empty fixture must have a nonzero cached total")
        let beforeClose = publications
        model.closeVolume()
        precondition(model.scannedSize == 0)
        // Allow the explicit final save to settle before removing the fixture.
        try await Task.sleep(for: .milliseconds(100))
        let restored = await store.load(for: volume)
        guard restored?.count == 502 else { print("FAIL: persisted \(restored?.count ?? -1)"); exit(1) }
        print("PASS: persisted 502 complete results; scan publications \(beforeClose)")
        withExtendedLifetime(subscription) {}
    }
}
