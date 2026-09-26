import Foundation

/// Immutable per-directory chunks plus an atomic manifest. Updating one subtree
/// does not serialize or rewrite the rest of a large volume index.
actor SpaceTableIndexStore {
    private struct Manifest: Codable {
        let version: Int
        let volumePath: String
        let capacity: Int64
        let used: Int64
        let savedAt: Date
        let files: [String: String]
    }

    private let fileManager: FileManager
    private let baseURL: URL
    private let maximumAge: TimeInterval
    private let beforeCommit: () throws -> Void
    private var previousVolume: String?
    private var previousResults: [String: SpaceTableScanResult] = [:]
    private var previousFiles: [String: String] = [:]
    private(set) var writtenChunkCount = 0

    init(fileManager: FileManager = .default, baseURL: URL? = nil, maximumAge: TimeInterval = 24 * 60 * 60, beforeCommit: @escaping () throws -> Void = {}) {
        self.fileManager = fileManager
        self.beforeCommit = beforeCommit
        self.maximumAge = maximumAge
        self.baseURL = baseURL ?? (fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory).appendingPathComponent("com.puremac.app/SpaceTable", isDirectory: true)
    }

    func load(for volume: SpaceTableVolume) -> [String: SpaceTableScanResult]? {
        let directory = cacheURL(for: volume.path)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.plist")),
              let manifest = try? PropertyListDecoder().decode(Manifest.self, from: data),
              manifest.version == 3, manifest.volumePath == volume.path,
              manifest.capacity == volume.totalSize,
              Date().timeIntervalSince(manifest.savedAt) <= maximumAge,
              abs(manifest.used - volume.usedSize) <= max(Int64(128 * 1024 * 1024), volume.totalSize / 200),
              manifest.files[volume.path] != nil else { return nil }
        var results: [String: SpaceTableScanResult] = [:]
        for (path, filename) in manifest.files {
            guard UUID(uuidString: filename) != nil,
                  let data = try? Data(contentsOf: directory.appendingPathComponent(filename)),
                  let result = try? PropertyListDecoder().decode(SpaceTableScanResult.self, from: data) else { return nil }
            results[path] = result
        }
        previousVolume = volume.path
        previousResults = results
        previousFiles = manifest.files
        return results
    }

    func save(directories: [String: SpaceTableScanResult], for volume: SpaceTableVolume) {
        guard directories[volume.path] != nil else { return }
        let directory = cacheURL(for: volume.path)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        var files: [String: String] = [:]
        var createdFiles: [URL] = []
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            for (path, result) in directories {
                if previousVolume == volume.path, previousResults[path] == result,
                   let filename = previousFiles[path],
                   fileManager.fileExists(atPath: directory.appendingPathComponent(filename).path) {
                    files[path] = filename
                } else {
                    let filename = UUID().uuidString
                    try encoder.encode(result).write(to: directory.appendingPathComponent(filename), options: .atomic)
                    createdFiles.append(directory.appendingPathComponent(filename))
                    writtenChunkCount += 1
                    files[path] = filename
                }
            }
            let manifest = Manifest(version: 3, volumePath: volume.path, capacity: volume.totalSize,
                used: volume.usedSize, savedAt: Date(), files: files)
            try beforeCommit()
            try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.plist"), options: .atomic)
            previousVolume = volume.path
            previousResults = directories
            previousFiles = files
            // Only obsolete chunks owned by this cache are removed after commit.
            let retained = Set(files.values)
            for filename in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] {
                if UUID(uuidString: filename) != nil, !retained.contains(filename) {
                    try? fileManager.removeItem(at: directory.appendingPathComponent(filename))
                }
            }
        } catch {
            // Failed saves leave the prior manifest and its chunks intact.
            for file in createdFiles { try? fileManager.removeItem(at: file) }
        }
    }

    func remove(for volumePath: String) {
        try? fileManager.removeItem(at: cacheURL(for: volumePath))
        if previousVolume == volumePath {
            previousVolume = nil
            previousResults = [:]
            previousFiles = [:]
        }
    }

    private func cacheURL(for path: String) -> URL {
        let name = Data(path.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return baseURL.appendingPathComponent("\(name.isEmpty ? "root" : name).index", isDirectory: true)
    }
}
