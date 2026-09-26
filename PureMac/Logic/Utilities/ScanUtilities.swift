import Foundation

final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

enum PathCoverage {
    static func roots(_ paths: [String]) -> [String] {
        let all = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        return all.filter { path in
            var ancestor = (path as NSString).deletingLastPathComponent
            while !ancestor.isEmpty, ancestor != path {
                if all.contains(ancestor) { return false }
                let next = (ancestor as NSString).deletingLastPathComponent
                if next == ancestor { break }
                ancestor = next
            }
            return true
        }.sorted()
    }
}

/// Linear candidate matching for ordinary ASCII bundle identifiers/names.
/// Unicode candidates retain String.contains semantics, including canonical
/// equivalence and matches that do not coincide with Character boundaries.
struct AppOwnershipIndex: Sendable {
    private struct Node: Sendable {
        var edges: [UInt8: Int] = [:]
        var failure = 0
        var terminal = false
    }
    private let patterns: [String]
    private let unicodePatterns: [String]
    private var nodes = [Node()]
    private var hasEmpty = false

    init(patterns: [String]) {
        self.patterns = Array(Set(patterns))
        self.unicodePatterns = self.patterns.filter { !$0.utf8.allSatisfy { $0 < 128 } }
        for pattern in self.patterns {
            if pattern.isEmpty { hasEmpty = true; continue }
            guard pattern.utf8.allSatisfy({ $0 < 128 }) else { continue }
            var state = 0
            for byte in pattern.utf8 {
                if let next = nodes[state].edges[byte] { state = next }
                else {
                    let next = nodes.count
                    nodes.append(Node())
                    nodes[state].edges[byte] = next
                    state = next
                }
            }
            nodes[state].terminal = true
        }
        var queue = Array(nodes[0].edges.values)
        var head = 0
        while head < queue.count {
            let state = queue[head]; head += 1
            for (byte, next) in nodes[state].edges {
                var fallback = nodes[state].failure
                while fallback != 0, nodes[fallback].edges[byte] == nil {
                    fallback = nodes[fallback].failure
                }
                nodes[next].failure = nodes[fallback].edges[byte] ?? 0
                nodes[next].terminal = nodes[next].terminal || nodes[nodes[next].failure].terminal
                queue.append(next)
            }
        }
    }

    func containsMatch(in candidate: String) -> Bool {
        if hasEmpty && candidate.contains("") { return true }
        guard candidate.utf8.allSatisfy({ $0 < 128 }) else {
            return patterns.contains { candidate.contains($0) }
        }
        var state = 0
        for byte in candidate.utf8 {
            while state != 0, nodes[state].edges[byte] == nil { state = nodes[state].failure }
            state = nodes[state].edges[byte] ?? 0
            if nodes[state].terminal { return true }
        }
        // A non-ASCII pattern can be canonically equal to ASCII (e.g. Kelvin
        // sign). Preserve that unusual case without putting it in the trie.
        return unicodePatterns.contains { candidate.contains($0) }
    }
}
