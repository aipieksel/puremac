import Foundation

/// Compiled alongside the production scanner by run-space-table.sh.
/// Uses only temporary fixtures; never scans the user's disk.
@main
struct SpaceTableBenchmark {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("PureMac-Performance-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var expected: [String: Int64] = [root.path: 0]
        var fileCount = 0
        for branch in 0..<24 {
            for depth in 0..<8 {
                let parts = ["branch-\(branch)"] + (0...depth).map { "level-\($0)" }
                let folder = parts.reduce(root) { $0.appendingPathComponent($1) }
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                for file in 0..<12 {
                    let url = folder.appendingPathComponent(file == 0 ? ".hidden" : "file-\(file)")
                    try Data(repeating: UInt8(file), count: 4096).write(to: url)
                    let size = Int64(try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0)
                    var parent = folder
                    while parent.path != root.path {
                        expected[parent.path, default: 0] += size
                        parent.deleteLastPathComponent()
                    }
                    expected[root.path, default: 0] += size
                    fileCount += 1
                }
            }
        }
        let empty = root.appendingPathComponent("empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        expected[empty.path] = 0
        let photos = root.appendingPathComponent("Photos.photoslibrary")
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 8192).write(to: photos.appendingPathComponent("private-photo"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root)

        var timings: [Double] = []
        // First run warms metadata caches; report five subsequent runs.
        for run in 0..<6 {
            let start = ContinuousClock.now
            let index = try await SpaceTableScanner().indexDirectoryTree(at: root.path)
            let elapsed = start.duration(to: .now).components
            if run > 0 { timings.append(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18) }
            precondition(Set(index.keys) == Set(expected.keys), "Missing or unexpected directory keys")
            for (path, total) in expected {
                let result = index[path]!
                precondition(result.unreadableItemCount == 0)
                precondition(result.items.reduce(Int64(0)) { $0 + $1.size } == total, "Incorrect total: \(path)")
                for item in result.items where item.isDirectory {
                    precondition(item.size == expected[item.path], "Incorrect child rollup: \(item.path)")
                }
                for pair in zip(result.items, result.items.dropFirst()) {
                    precondition(pair.0.size >= pair.1.size, "Results are not size sorted")
                }
            }
            let top = index[root.path]!.items
            precondition(!top.contains { $0.name == "link" })
            let package = top.first { $0.name == "Photos.photoslibrary" }!
            precondition(!package.isDirectory && package.size == 0)
        }
        print("Verified \(fileCount) payload files, \(expected.count) directories, hidden files, empty folders, symlinks, Photos exclusion and logical root paths.")
        print("Warm seconds: \(timings)")
        print("Median seconds: \(timings.sorted()[timings.count / 2])")
    }
}
