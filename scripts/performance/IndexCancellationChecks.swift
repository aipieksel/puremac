import Foundation

@main struct IndexCancellationChecks {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("PureMac-Cancel-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for i in 0..<1500 {
            let directory = root.appendingPathComponent("directory-\(i)")
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 7, count: 4096).write(to: directory.appendingPathComponent("payload"))
        }
        let scanner = SpaceTableScanner()
        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await scanner.indexDirectoryTree(at: root.path)
        }
        do {
            _ = try await preCancelled.value
            print("FAIL: pre-cancelled caller still completed the entire index")
            exit(1)
        } catch is CancellationError {}

        let inFlight = Task { try await scanner.indexDirectoryTree(at: root.path) }
        try await Task.sleep(for: .milliseconds(20))
        let start = ContinuousClock.now
        inFlight.cancel()
        do {
            _ = try await inFlight.value
            print("FAIL: in-flight cancellation still returned a complete index")
            exit(1)
        } catch is CancellationError {}
        print("PASS: pre-cancelled and in-flight index tasks throw CancellationError; cancellation latency \(start.duration(to: .now))")
    }
}
