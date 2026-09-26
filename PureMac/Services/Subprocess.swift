import Foundation
import Darwin

/// Captures both streams without blocking on either pipe or retaining unlimited
/// output. Never invokes a shell. Callers own command selection and exit handling.
enum Subprocess {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    enum Failure: Error, LocalizedError {
        case timedOut
        case outputLimitExceeded
        case readFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .timedOut: return "The command exceeded its time limit."
            case .outputLimitExceeded: return "The command exceeded its output limit."
            case .readFailed(let code): return "Could not read command output (errno \(code))."
            }
        }
    }

    static func run(
        _ process: Process,
        timeout: TimeInterval = 30,
        outputLimit: Int = 8 * 1024 * 1024,
        discardStderr: Bool = false
    ) throws -> Output {
        try Task.checkCancellation()
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let handles = [stdout.fileHandleForReading, stderr.fileHandleForReading]
        defer { for handle in handles { try? handle.close() } }
        for handle in handles {
            let fd = handle.fileDescriptor
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else {
                throw Failure.readFailed(errno)
            }
        }
        try process.run()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var stoppedAt: TimeInterval?
        var failure: Error?
        var buffers = [Data(), Data()]
        var descriptors = handles.map { pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0) }
        var bytes = [UInt8](repeating: 0, count: 32 * 1024)

        while process.isRunning || descriptors.contains(where: { $0.fd >= 0 }) {
            let now = ProcessInfo.processInfo.systemUptime
            if failure == nil {
                if Task.isCancelled { failure = CancellationError() }
                else if now >= deadline { failure = Failure.timedOut }
            }
            if failure != nil, stoppedAt == nil {
                stoppedAt = now
                if process.isRunning { process.terminate() }
            }
            if let stoppedAt, now - stoppedAt >= 1, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            // A descendant may retain a pipe after its parent exits. Do not
            // wait forever for its EOF; close our read ends at the deadline.
            if let stoppedAt, now - stoppedAt >= 2 { break }

            let polled = poll(&descriptors, nfds_t(descriptors.count), 50)
            if polled < 0, errno != EINTR { failure = Failure.readFailed(errno) }
            for index in descriptors.indices where descriptors[index].fd >= 0 {
                guard descriptors[index].revents != 0 else { continue }
                // Bound each drain turn so a continuously chatty stream cannot
                // starve the other stream, cancellation, or deadline checks.
                for _ in 0..<16 {
                    let count = read(descriptors[index].fd, &bytes, bytes.count)
                    if count > 0 {
                        if index == 1 && discardStderr { continue }
                        let remaining = max(0, outputLimit - buffers[index].count)
                        buffers[index].append(contentsOf: bytes.prefix(min(count, remaining)))
                        if count > remaining, failure == nil { failure = Failure.outputLimitExceeded }
                    } else if count == 0 {
                        descriptors[index].fd = -1
                        break
                    } else {
                        if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                            failure = Failure.readFailed(errno)
                            descriptors[index].fd = -1
                        }
                        break
                    }
                }
            }
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        if let failure { throw failure }
        try Task.checkCancellation()
        return Output(status: process.terminationStatus, stdout: buffers[0], stderr: buffers[1])
    }

    static func runAsync(
        _ process: Process,
        timeout: TimeInterval = 30,
        outputLimit: Int = 8 * 1024 * 1024,
        discardStderr: Bool = false
    ) async throws -> Output {
        let worker = Task.detached(priority: Task.currentPriority) {
            try run(process, timeout: timeout, outputLimit: outputLimit, discardStderr: discardStderr)
        }
        return try await withTaskCancellationHandler {
            let output = try await worker.value
            try Task.checkCancellation()
            return output
        } onCancel: { worker.cancel() }
    }
}
