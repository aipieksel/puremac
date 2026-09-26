import XCTest
@testable import PureMac

final class SpaceTableTests: XCTestCase {
    func testVolumeUsageIsClampedAndCalculatedFromAvailableSpace() {
        let volume = SpaceTableVolume(
            name: "Test",
            path: "/test",
            totalSize: 1_000,
            availableSize: 250
        )

        XCTAssertEqual(volume.usedSize, 750)
        XCTAssertEqual(volume.usageFraction, 0.75, accuracy: 0.0001)
    }

    func testScannerCountsNestedFilesAndDoesNotFollowSymlinks() async throws {
        let root = makeTemporaryDirectory(named: "PureMac-SpaceTable")
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data(repeating: 0x5A, count: 32 * 1024)
        try payload.write(to: folder.appendingPathComponent("payload.bin"))
        let topLevelFile = root.appendingPathComponent("top-level.bin")
        try payload.write(to: topLevelFile)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Folder Link"),
            withDestinationURL: folder
        )

        let result = try await SpaceTableScanner().scanDirectory(at: root.path) { _, _ in }

        XCTAssertEqual(Set(result.items.map(\.name)), ["Folder", "top-level.bin"])
        let folderResult = try XCTUnwrap(result.items.first(where: { $0.name == "Folder" }))
        let fileResult = try XCTUnwrap(result.items.first(where: { $0.name == "top-level.bin" }))
        XCTAssertGreaterThan(folderResult.size, 0)
        XCTAssertTrue(folderResult.isDirectory)
        XCTAssertEqual(
            fileResult.size,
            Int64(try topLevelFile.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0)
        )
    }

    func testScannerDoesNotEnterPhotoLibraryPackages() async throws {
        let root = makeTemporaryDirectory(named: "PureMac-SpaceTable-Photos")
        let library = root.appendingPathComponent("Photos Library.photoslibrary", isDirectory: true)
        let originals = library.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 0x5A, count: 32 * 1024)
            .write(to: originals.appendingPathComponent("protected-photo.jpg"))

        let result = try await SpaceTableScanner().scanDirectory(at: root.path) { _, _ in }
        let item = try XCTUnwrap(result.items.first(where: { $0.name == "Photos Library.photoslibrary" }))

        XCTAssertFalse(item.isDirectory)
        XCTAssertEqual(item.size, 0)

        let directResult = try await SpaceTableScanner().scanDirectory(at: library.path) { _, _ in }
        XCTAssertTrue(directResult.items.isEmpty)
    }

    func testScannerExcludesPhotoLibraryNestedInsideOrdinaryFolder() async throws {
        let root = makeTemporaryDirectory(named: "PureMac-SpaceTable-Nested-Photos")
        let ordinaryFolder = root.appendingPathComponent("Ordinary Folder", isDirectory: true)
        let originals = ordinaryFolder
            .appendingPathComponent("Photos Library.photoslibrary", isDirectory: true)
            .appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 0x5A, count: 4 * 1_024 * 1_024)
            .write(to: originals.appendingPathComponent("protected-photo.jpg"))

        let result = try await SpaceTableScanner().scanDirectory(at: root.path) { _, _ in }
        let item = try XCTUnwrap(result.items.first(where: { $0.name == "Ordinary Folder" }))

        XCTAssertLessThan(item.size, 1_024 * 1_024)
    }

    func testScannerIncludesHiddenFoldersAndFiles() async throws {
        let root = makeTemporaryDirectory(named: "PureMac-SpaceTable-Hidden")
        let hiddenFolder = root.appendingPathComponent(".hidden-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 0x5A, count: 8 * 1_024)
            .write(to: hiddenFolder.appendingPathComponent(".hidden-child"))
        try Data(repeating: 0x5A, count: 8 * 1_024)
            .write(to: root.appendingPathComponent(".hidden-file"))

        let result = try await SpaceTableScanner().scanDirectory(at: root.path) { _, _ in }

        XCTAssertEqual(Set(result.items.map(\.name)), [".hidden-folder", ".hidden-file"])
    }

    func testDirectoryPreviewPublishesChildrenWithoutWalkingDescendants() async throws {
        let root = makeTemporaryDirectory(named: "PureMac-SpaceTable-Preview")
        let nested = root
            .appendingPathComponent("Largest", isDirectory: true)
            .appendingPathComponent("Deep", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<256 {
            try Data(repeating: 0x5A, count: 4 * 1_024)
                .write(to: nested.appendingPathComponent("file-\(index).bin"))
        }

        let preview = try await SpaceTableScanner().previewDirectory(
            at: root.appendingPathComponent("Largest").path
        )
        let deepFolder = try XCTUnwrap(
            preview.items.first(where: { $0.name == "Deep" })
        )

        XCTAssertTrue(deepFolder.isDirectory)
        XCTAssertEqual(deepFolder.size, 0)
        XCTAssertEqual(preview.items.count, 1)
    }

    func testBackgroundTreeIndexBuildsEveryDirectoryInOnePass() async throws {
        let root = makeTemporaryDirectory(named: "PureMac-SpaceTable-Tree-Index")
        let first = root.appendingPathComponent("First", isDirectory: true)
        let second = first.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 0x5A, count: 64 * 1_024)
            .write(to: second.appendingPathComponent("nested.bin"))
        try Data(repeating: 0xA5, count: 16 * 1_024)
            .write(to: root.appendingPathComponent(".hidden.bin"))

        let scanner = SpaceTableScanner()
        let index = try await scanner.indexDirectoryTree(at: root.path)

        let rootResult = try XCTUnwrap(index[root.path], "Index keys: \(index.keys.sorted())")
        let firstResult = try XCTUnwrap(index[first.path], "Index keys: \(index.keys.sorted())")
        let secondResult = try XCTUnwrap(index[second.path], "Index keys: \(index.keys.sorted())")
        XCTAssertEqual(Set(rootResult.items.map(\.name)), ["First", ".hidden.bin"])
        XCTAssertEqual(firstResult.items.map(\.name), ["Second"])
        XCTAssertEqual(secondResult.items.map(\.name), ["nested.bin"])
        XCTAssertGreaterThan(rootResult.items.first(where: { $0.name == "First" })?.size ?? 0, 0)
    }

    func testBackgroundTreeIndexSkipsSymlinksAndPhotoLibraryContents() async throws {
        let root = makeTemporaryDirectory(named: "PureMac-SpaceTable-Tree-Privacy")
        let ordinary = root.appendingPathComponent("Ordinary", isDirectory: true)
        let library = root.appendingPathComponent("Photos Library.photoslibrary", isDirectory: true)
        let originals = library.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 0x5A, count: 32 * 1_024)
            .write(to: originals.appendingPathComponent("protected-photo.jpg"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Ordinary Link"),
            withDestinationURL: ordinary
        )

        let index = try await SpaceTableScanner().indexDirectoryTree(at: root.path)
        let rootResult = try XCTUnwrap(index[root.path])

        XCTAssertNil(index[library.path])
        XCTAssertNil(index[originals.path])
        XCTAssertFalse(rootResult.items.contains(where: { $0.name == "Ordinary Link" }))
        let package = try XCTUnwrap(
            rootResult.items.first(where: { $0.name == "Photos Library.photoslibrary" }),
            "Root items: \(rootResult.items.map(\.path))"
        )
        XCTAssertFalse(package.isDirectory)
        XCTAssertEqual(package.size, 0)
    }

    func testPersistentIndexStoreRestoresAndInvalidatesChangedVolumes() async throws {
        let root = makeTemporaryDirectory(named: "PureMac-SpaceTable-Index-Store")
        let cache = root.appendingPathComponent("Cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let volume = SpaceTableVolume(
            name: "Fixture",
            path: root.path,
            totalSize: 1_000_000_000,
            availableSize: 500_000_000
        )
        let item = SpaceTableItem(
            name: "Folder",
            path: root.appendingPathComponent("Folder").path,
            size: 42,
            isDirectory: true,
            modificationDate: nil
        )
        let directories = [
            root.path: SpaceTableScanResult(items: [item], unreadableItemCount: 0)
        ]
        let store = SpaceTableIndexStore(baseURL: cache)

        await store.save(directories: directories, for: volume)
        let restored = await store.load(for: volume)
        XCTAssertEqual(restored?[root.path]?.items.map(\.name), ["Folder"])

        let materiallyChanged = SpaceTableVolume(
            name: volume.name,
            path: volume.path,
            totalSize: volume.totalSize,
            availableSize: volume.availableSize - 200_000_000
        )
        let invalidated = await store.load(for: materiallyChanged)
        XCTAssertNil(invalidated)
    }

    @MainActor
    func testViewModelRestoresPersistentIndexWhenOpeningVolume() async throws {
        let root = makeTemporaryDirectory(named: "PureMac-SpaceTable-Restore")
        let cache = root.appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let volume = SpaceTableVolume(
            name: "Fixture",
            path: root.path,
            totalSize: 1_000_000,
            availableSize: 500_000
        )
        let cachedItem = SpaceTableItem(
            name: "restored.bin",
            path: root.appendingPathComponent("restored.bin").path,
            size: 42,
            isDirectory: false,
            modificationDate: nil
        )
        let store = SpaceTableIndexStore(baseURL: cache)
        await store.save(
            directories: [
                root.path: SpaceTableScanResult(items: [cachedItem], unreadableItemCount: 0)
            ],
            for: volume
        )

        let viewModel = SpaceTableViewModel(indexStore: store)
        viewModel.openVolume(volume)
        try await waitForScan(viewModel)

        XCTAssertEqual(viewModel.state, .complete)
        XCTAssertEqual(viewModel.items.map(\.name), ["restored.bin"])
        XCTAssertEqual(viewModel.indexedFolderCount, 1)
    }

    func testParallelScanMatchesSingleWorkerResults() async throws {
        let root = makeTemporaryDirectory(named: "PureMac-SpaceTable-Parallel")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for folderIndex in 0..<12 {
            let folder = root.appendingPathComponent("Folder \(folderIndex)", isDirectory: true)
            let nested = folder.appendingPathComponent("Nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            for fileIndex in 0..<8 {
                try Data(repeating: UInt8(folderIndex), count: (fileIndex + 1) * 4096)
                    .write(to: nested.appendingPathComponent("file-\(fileIndex).bin"))
            }
        }

        let singleWorker = try await SpaceTableScanner(maxConcurrentWorkers: 1)
            .scanDirectory(at: root.path) { _, _ in }
        let parallel = try await SpaceTableScanner(maxConcurrentWorkers: 8)
            .scanDirectory(at: root.path) { _, _ in }

        let singleItems = Dictionary(uniqueKeysWithValues: singleWorker.items.map {
            ($0.name, [$0.size, $0.isDirectory ? 1 : 0])
        })
        let parallelItems = Dictionary(uniqueKeysWithValues: parallel.items.map {
            ($0.name, [$0.size, $0.isDirectory ? 1 : 0])
        })
        XCTAssertEqual(parallelItems, singleItems)
        XCTAssertEqual(parallel.unreadableItemCount, singleWorker.unreadableItemCount)
    }

    func testDeepShardedScanMatchesSingleWorkerResults() async throws {
        let root = makeTemporaryDirectory(named: "PureMac-SpaceTable-Sharded")
        let topFolder = root.appendingPathComponent("Users", isDirectory: true)
        try FileManager.default.createDirectory(at: topFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for folderIndex in 0..<16 {
            let folder = topFolder.appendingPathComponent("Folder \(folderIndex)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for fileIndex in 0..<12 {
                try Data(repeating: UInt8(folderIndex), count: (fileIndex + 1) * 2_048)
                    .write(to: folder.appendingPathComponent("file-\(fileIndex).bin"))
            }
        }

        let singleWorker = try await SpaceTableScanner(maxConcurrentWorkers: 1)
            .scanDirectory(at: root.path) { _, _ in }
        let sharded = try await SpaceTableScanner(
            maxConcurrentWorkers: 8,
            shardAllDirectories: true
        ).scanDirectory(at: root.path) { _, _ in }

        XCTAssertEqual(sharded.items.count, singleWorker.items.count)
        XCTAssertEqual(sharded.items.first?.name, singleWorker.items.first?.name)
        let shardedSize = try XCTUnwrap(sharded.items.first?.size)
        let singleSize = try XCTUnwrap(singleWorker.items.first?.size)
        XCTAssertLessThanOrEqual(abs(shardedSize - singleSize), 64 * 1_024)
    }

    func testScanCanBeCancelled() async throws {
        let root = makeTemporaryDirectory(named: "PureMac-SpaceTable-Cancel")
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<1_024 {
            FileManager.default.createFile(
                atPath: folder.appendingPathComponent("file-\(index)").path,
                contents: Data()
            )
        }

        let task = Task {
            try await SpaceTableScanner().scanDirectory(at: root.path) { _, _ in }
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled Space Table scan should throw CancellationError")
        } catch is CancellationError {
            // Expected.
        }
    }

    @MainActor
    func testViewModelCachesScannedFoldersForInstantBackNavigation() async throws {
        let root = makeTemporaryDirectory(named: "PureMac-SpaceTable-Cache")
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x5A, count: 16 * 1_024)
            .write(to: folder.appendingPathComponent("file.bin"))

        let viewModel = SpaceTableViewModel()
        viewModel.selectVolume(
            SpaceTableVolume(
                name: "Fixture",
                path: root.path,
                totalSize: 1_000_000,
                availableSize: 500_000
            )
        )
        viewModel.scanSelectedVolume()
        try await waitForScan(viewModel)
        let folderItem = try XCTUnwrap(viewModel.items.first(where: { $0.name == "Folder" }))

        viewModel.open(folderItem)
        try await waitForScan(viewModel)
        XCTAssertEqual(
            viewModel.currentPath.map { URL(fileURLWithPath: $0).lastPathComponent },
            "Folder"
        )

        try FileManager.default.removeItem(at: root)
        viewModel.navigateBack()

        XCTAssertEqual(viewModel.state, .complete)
        XCTAssertEqual(viewModel.currentPath, root.path)
        XCTAssertEqual(viewModel.items.first?.name, "Folder")
    }

    @MainActor
    func testViewModelIndexesNestedFoldersInBackground() async throws {
        let root = makeTemporaryDirectory(named: "PureMac-SpaceTable-Background")
        let first = root.appendingPathComponent("First", isDirectory: true)
        let second = first.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x5A, count: 4 * 1_024)
            .write(to: second.appendingPathComponent("file.bin"))

        let viewModel = SpaceTableViewModel()
        viewModel.selectVolume(
            SpaceTableVolume(
                name: "Fixture",
                path: root.path,
                totalSize: 1_000_000,
                availableSize: 500_000
            )
        )
        viewModel.scanSelectedVolume()
        try await waitForScan(viewModel)
        try await waitUntil {
            viewModel.indexedFolderCount >= 3
        }

        XCTAssertGreaterThanOrEqual(viewModel.indexedFolderCount, 3)
        let firstItem = try XCTUnwrap(viewModel.items.first(where: { $0.name == "First" }))
        XCTAssertTrue(
            viewModel.isIndexed(firstItem.path),
            "Expected the foreground item path to match a background index key: \(firstItem.path)"
        )
        let secondItem = try XCTUnwrap(
            viewModel.indexedChildren(of: firstItem)?.first(where: { $0.name == "Second" }),
            "Indexed children: \(viewModel.indexedChildren(of: firstItem)?.map(\.path) ?? [])"
        )
        XCTAssertNotNil(viewModel.indexedChildren(of: secondItem))
    }

    @MainActor
    func testReselectingSameVolumeDoesNotStopBackgroundReadiness() async throws {
        let root = makeTemporaryDirectory(named: "PureMac-SpaceTable-Continue")
        let largest = root
            .appendingPathComponent("Largest", isDirectory: true)
            .appendingPathComponent("Deep", isDirectory: true)
        try FileManager.default.createDirectory(at: largest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<1_024 {
            try Data(repeating: 0x5A, count: 1_024)
                .write(to: largest.appendingPathComponent("file-\(index).bin"))
        }

        let volume = SpaceTableVolume(
            name: "Fixture",
            path: root.path,
            totalSize: 10_000_000,
            availableSize: 5_000_000
        )
        let viewModel = SpaceTableViewModel()
        viewModel.selectVolume(volume)
        viewModel.scanSelectedVolume()
        try await waitForScan(viewModel)

        viewModel.selectVolume(volume)
        viewModel.resumeBackgroundIndexing()
        let largestItem = try XCTUnwrap(
            viewModel.items.first(where: { $0.name == "Largest" })
        )
        try await waitUntil {
            viewModel.indexedChildren(of: largestItem) != nil
        }

        XCTAssertEqual(
            viewModel.indexedChildren(of: largestItem)?.map(\.name),
            ["Deep"]
        )
    }

    @MainActor
    func testSpaceTableSelectionPersistsAcrossFolderNavigation() async throws {
        let root = makeTemporaryDirectory(named: "PureMac-SpaceTable-Selection")
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x5A, count: 4 * 1_024)
            .write(to: root.appendingPathComponent("keep-selected.bin"))

        let viewModel = SpaceTableViewModel()
        viewModel.selectVolume(
            SpaceTableVolume(
                name: "Fixture",
                path: root.path,
                totalSize: 1_000_000,
                availableSize: 500_000
            )
        )
        viewModel.scanSelectedVolume()
        try await waitForScan(viewModel)

        let file = try XCTUnwrap(
            viewModel.items.first(where: { $0.name == "keep-selected.bin" })
        )
        let folderItem = try XCTUnwrap(
            viewModel.items.first(where: { $0.name == "Folder" })
        )
        viewModel.setSelected(file, selected: true)
        viewModel.open(folderItem)
        try await waitForScan(viewModel)

        XCTAssertTrue(viewModel.isSelected(file))
        XCTAssertEqual(viewModel.selectedCount, 1)
    }

    @MainActor
    func testMovingSelectedItemsToTrashUpdatesTheCurrentListing() async throws {
        let root = makeTemporaryDirectory(named: "PureMac-SpaceTable-Trash")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selectedURL = root.appendingPathComponent("selected.bin")
        try Data(repeating: 0x5A, count: 4 * 1_024).write(to: selectedURL)

        let viewModel = SpaceTableViewModel(trashHandler: { paths in
            SpaceTableTrashResult(removedPaths: paths, failures: [:])
        })
        viewModel.selectVolume(
            SpaceTableVolume(
                name: "Fixture",
                path: root.path,
                totalSize: 1_000_000,
                availableSize: 500_000
            )
        )
        viewModel.scanSelectedVolume()
        try await waitForScan(viewModel)

        let item = try XCTUnwrap(viewModel.items.first(where: { $0.name == "selected.bin" }))
        viewModel.setSelected(item, selected: true)
        viewModel.moveSelectedItemsToTrash()
        try await waitUntil { !viewModel.isMovingToTrash }

        XCTAssertEqual(viewModel.selectedCount, 0)
        XCTAssertFalse(viewModel.items.contains(where: { $0.name == "selected.bin" }))
        XCTAssertNil(viewModel.deletionError)
    }

    @MainActor
    private func waitForScan(
        _ viewModel: SpaceTableViewModel,
        timeout: Duration = .seconds(5)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while viewModel.state.isScanning, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(viewModel.state.isScanning)
        if case .failed(let message) = viewModel.state {
            XCTFail("Space Table scan failed: \(message)")
        }
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }

    private func makeTemporaryDirectory(named name: String) -> URL {
        let baseURL: URL
        if let override = ProcessInfo.processInfo.environment["PUREMAC_TEST_TMP"] {
            baseURL = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            baseURL = FileManager.default.temporaryDirectory
        }
        return baseURL.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }

}
