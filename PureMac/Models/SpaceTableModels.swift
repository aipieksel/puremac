import Foundation

struct SpaceTableVolume: Identifiable, Hashable, Sendable, Codable {
    let name: String
    let path: String
    let totalSize: Int64
    let availableSize: Int64

    var id: String { path }
    var usedSize: Int64 { max(0, totalSize - availableSize) }

    var usageFraction: Double {
        guard totalSize > 0 else { return 0 }
        return min(max(Double(usedSize) / Double(totalSize), 0), 1)
    }
}

struct SpaceTableItem: Identifiable, Hashable, Sendable, Codable {
    let name: String
    let path: String
    let size: Int64
    let isDirectory: Bool
    let modificationDate: Date?

    var id: String { path }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct SpaceTableScanResult: Sendable, Codable, Equatable {
    let items: [SpaceTableItem]
    let unreadableItemCount: Int
}

struct SpaceTableTrashResult: Sendable {
    let removedPaths: [String]
    let failures: [String: String]
}

enum SpaceTableScanState: Equatable {
    case idle
    case scanning(path: String, discoveredBytes: Int64)
    case complete
    case failed(message: String)

    var isScanning: Bool {
        if case .scanning = self { return true }
        return false
    }
}

