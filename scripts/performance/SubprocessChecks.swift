import Foundation

@main struct SubprocessChecks {
    static func process(_ code: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", code]
        return process
    }
    static func main() async throws {
        let chatty = try await Subprocess.runAsync(process("import os; os.write(2,b'E'*2097152); os.write(1,b'O'*2097152)"))
        precondition(chatty.status == 0 && chatty.stdout.count == 2097152 && chatty.stderr.count == 2097152)
        let discarded = try await Subprocess.runAsync(process("import os; os.write(2,b'E'*1048576); os.write(1,b'ok')"), outputLimit: 1024, discardStderr: true)
        precondition(discarded.stderr.isEmpty && String(data: discarded.stdout, encoding: .utf8) == "ok")
        let failed = try Subprocess.run(process("import os; os.write(2,b'failed'); os._exit(7)"))
        precondition(failed.status == 7 && String(data: failed.stderr, encoding: .utf8) == "failed")
        do {
            _ = try Subprocess.run(process("import os; os.write(1,b'x'*1048576)"), outputLimit: 1024)
            fatalError("Expected bounded output failure")
        } catch Subprocess.Failure.outputLimitExceeded {}
        let stubborn = process("import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)")
        let start = ContinuousClock.now
        do {
            _ = try await Subprocess.runAsync(stubborn, timeout: 0.2)
            fatalError("Expected timeout")
        } catch Subprocess.Failure.timedOut {}
        precondition(!stubborn.isRunning && start.duration(to: .now) < .seconds(3))
        let sleeping = process("import time; time.sleep(30)")
        let task = Task { try await Subprocess.runAsync(sleeping) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; fatalError("Expected cancellation") } catch is CancellationError {}
        precondition(!sleeping.isRunning)
        let paths = (0..<10000).map { "/fixture/" + String(repeating: "long-name", count: 20) + "-\($0)" }
        let chunks = SpaceTableScanner.argumentChunks(paths)
        precondition(chunks.flatMap { $0 } == paths)
        precondition(chunks.allSatisfy { $0.count <= 128 && $0.reduce(0) { $0 + $1.utf8.count + 9 } <= 32768 })
        print("PASS: real production runner drains both streams, preserves failure output, enforces output/deadline limits, kills stubborn children, cancels tasks, and bounds 10000 paths")
    }
}
