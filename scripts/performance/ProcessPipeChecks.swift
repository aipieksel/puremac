import Foundation

private final class Output: @unchecked Sendable {
    var data = Data()
}

@main struct ProcessPipeChecks {
    static func main() throws {
        // Exercise the I/O patterns only, using a harmless fixture child.
        // Do not run real package managers or any cleanup command.
        for mode in ["wait-before-read", "sequential-drain", "concurrent-drain"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", "import os; os.write(2, b'E' * 1048576); os.write(1, b'O' * 1048576)"]
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            let watchdog = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: watchdog)
            let out = Output(), err = Output()
            if mode == "wait-before-read" {
                process.waitUntilExit()
                out.data = stdout.fileHandleForReading.readDataToEndOfFile()
                err.data = stderr.fileHandleForReading.readDataToEndOfFile()
            } else if mode == "sequential-drain" {
                out.data = stdout.fileHandleForReading.readDataToEndOfFile()
                err.data = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
            } else {
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    out.data = stdout.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    err.data = stderr.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                process.waitUntilExit()
                group.wait()
            }
            watchdog.cancel()
            let complete = process.terminationStatus == 0 && out.data.count == 1048576 && err.data.count == 1048576
            precondition(complete == (mode == "concurrent-drain"))
            print("\(mode): \(complete ? "completed both 1 MiB streams" : "stalled; fixture child terminated by 2-second watchdog")")
        }
    }
}
