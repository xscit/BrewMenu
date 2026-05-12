import Foundation
import Darwin
import os

/// Homebrew command execution interface.
protocol BrewCommandRunner: Sendable {
    func execute(_ command: BrewCommand) async -> (stdout: String, stderr: String, exitCode: Int32)
    func terminateAll()
}

/// Single-shot flag that guarantees at most one caller wins the race to resume.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// Accumulates pipe output across GCD callbacks.
private final class DataBuffer: @unchecked Sendable {
    private var data = Data()
    func append(_ chunk: Data) { data.append(chunk) }
    func extract() -> Data { data }
}

/// Thread-safe registry of active process IDs.
private final class ActiveProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var pids = Set<pid_t>()

    func add(_ pid: pid_t) {
        lock.lock(); pids.insert(pid); lock.unlock()
    }

    func remove(_ pid: pid_t) {
        lock.lock(); pids.remove(pid); lock.unlock()
    }

    func terminateAll() -> Int {
        lock.lock()
        let snapshot = pids
        lock.unlock()

        guard !snapshot.isEmpty else { return 0 }

        // Send SIGINT to the entire process group (-pid).
        // This mimics a terminal Control-C, allowing brew to perform cleanup (locks, partial files).
        for pid in snapshot {
            kill(-pid, SIGINT)
        }

        // Escalate to SIGKILL for the group if processes don't exit within 5 seconds.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let remaining = self.pids.intersection(snapshot)
            self.lock.unlock()

            guard !remaining.isEmpty else { return }
            Log.brew.notice("Escalating to SIGKILL for \(remaining.count) process group(s) that ignored SIGINT.")
            for pid in remaining {
                kill(-pid, SIGKILL)
            }
        }

        return snapshot.count
    }
}

/// Production command executor: uses posix_spawn for atomic process group control.
final class RealBrewCommandRunner: BrewCommandRunner, @unchecked Sendable {
    private let registry = ActiveProcesses()

    func terminateAll() {
        let count = registry.terminateAll()
        if count > 0 {
            Log.brew.notice("Terminating \(count) active brew process(es) and their groups.")
        }
    }

    func execute(_ command: BrewCommand) async -> (stdout: String, stderr: String, exitCode: Int32) {
        let outPipe = Pipe()
        let errPipe = Pipe()

        let ioQueue = DispatchQueue(label: "com.whoami.brewmenu.io")
        let outBuffer = DataBuffer()
        let errBuffer = DataBuffer()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            ioQueue.async { outBuffer.append(chunk) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            ioQueue.async { errBuffer.append(chunk) }
        }

        return await withCheckedContinuation { continuation in
            let resumed = ResumeGuard()

            var pid: pid_t = 0
            let executablePath = command.executable.path
            let argvStrings = [executablePath] + command.args + command.packages

            // Environment setup
            var env = ProcessInfo.processInfo.environment
            let binURL = command.executable.deletingLastPathComponent()
            let prefixURL = binURL.deletingLastPathComponent()
            env["HOMEBREW_PREFIX"] = prefixURL.path
            env["PATH"] = "\(binURL.path):/usr/bin:/bin:/usr/sbin:/sbin"
            env["HOMEBREW_NO_COLOR"] = "1"
            env["HOMEBREW_NO_EMOJI"] = "1"
            env.merge(command.additionalEnvironment) { _, new in new }

            let envStrings = env.map { "\($0.key)=\($0.value)" }

            // POSIX spawn setup
            var fileActions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&fileActions)
            defer { posix_spawn_file_actions_destroy(&fileActions) }

            posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&fileActions, outPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&fileActions, errPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

            // Close ends in child
            posix_spawn_file_actions_addclose(&fileActions, outPipe.fileHandleForReading.fileDescriptor)
            posix_spawn_file_actions_addclose(&fileActions, errPipe.fileHandleForReading.fileDescriptor)
            posix_spawn_file_actions_addclose(&fileActions, outPipe.fileHandleForWriting.fileDescriptor)
            posix_spawn_file_actions_addclose(&fileActions, errPipe.fileHandleForWriting.fileDescriptor)

            var attr: posix_spawnattr_t?
            posix_spawnattr_init(&attr)
            defer { posix_spawnattr_destroy(&attr) }

            posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
            posix_spawnattr_setpgroup(&attr, 0)

            let status = withCStringArray(argvStrings) { cArgv in
                withCStringArray(envStrings) { cEnvp in
                    executablePath.withCString { cPath in
                        posix_spawn(&pid, cPath, &fileActions, &attr, cArgv, cEnvp)
                    }
                }
            }

            if status != 0 {
                Log.brew.error("posix_spawn failed: \(status)")
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: ("", "Failed to launch process", status))
                return
            }

            // CRITICAL: Close the writing ends in the parent process immediately.
            // If we don't, readDataToEndOfFile() will hang forever because the 
            // pipe remains open even after the child dies.
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()

            registry.add(pid)
            command.onPID?(pid)

            DispatchQueue.global(qos: .utility).async {
                var waitStatus: Int32 = 0
                waitpid(pid, &waitStatus, 0)

                self.registry.remove(pid)

                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil

                ioQueue.async {
                    outBuffer.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                    errBuffer.append(errPipe.fileHandleForReading.readDataToEndOfFile())

                    let stdout = String(data: outBuffer.extract(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let stderr = String(data: errBuffer.extract(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    let exitCode = WIFEXITED(waitStatus) ? WEXITSTATUS(waitStatus) : -1

                    guard resumed.claim() else { return }
                    continuation.resume(returning: (stdout, stderr, exitCode))
                }
            }
        }
    }
}

// MARK: - Helpers

private func withCStringArray<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<Int8>?>?) -> R) -> R {
    let cStrings = strings.map { strdup($0) }
    defer { cStrings.forEach { free($0) } }
    var pointers = cStrings.map { UnsafeMutablePointer<Int8>($0) }
    pointers.append(nil)
    return pointers.withUnsafeBufferPointer { body($0.baseAddress) }
}

private func WIFEXITED(_ status: Int32) -> Bool {
    return (status & 0x7f) == 0
}

private func WEXITSTATUS(_ status: Int32) -> Int32 {
    return (status >> 8) & 0xff
}
