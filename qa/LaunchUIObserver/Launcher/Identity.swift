import Foundation
import Darwin
import Security

enum LauncherFailure: Error { case unavailable }

struct LauncherBinding: Decodable {
    let copiedPath, snapshotPath, observationID: String
    var arguments: [String] {
        ["/usr/bin/open", "-n", "-W", copiedPath, "--args", "--demo", "--snapshot", snapshotPath]
    }
    func validate() throws {
        guard UUID(uuidString: observationID) != nil,
              copiedPath.hasPrefix("/"), copiedPath.hasSuffix("/Cadence.app"),
              snapshotPath.hasPrefix("/"), snapshotPath.hasSuffix("/startup.png"),
              [copiedPath, snapshotPath].allSatisfy({ $0.utf8.count <= 16384 && !$0.contains("\0") && !$0.contains("\n") && !$0.contains("\r") }) else {
            throw LauncherFailure.unavailable
        }
    }
}

struct LauncherIdentity: Codable, Equatable {
    let pid, parentPID: Int32
    let uid: UInt32
    let startSeconds, startMicroseconds: UInt64
    let executable: String

    static func read(_ pid: Int32) throws -> LauncherIdentity {
        var info = proc_bsdinfo()
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
              info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(), info.pbi_status != UInt32(SZOMB), info.pbi_start_tvsec > 0 else {
            throw LauncherFailure.unavailable
        }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard count > 0, path.contains(0) else { throw LauncherFailure.unavailable }
        return LauncherIdentity(pid: pid, parentPID: Int32(info.pbi_ppid), uid: info.pbi_uid,
            startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec, executable: String(cString: path))
    }
}

struct LauncherReceipt: Codable {
    let schema: String
    let observationID: String
    let launcherPID, supervisorPID: Int32
    let launcher, supervisor: LauncherIdentity
    let arguments: [String]
}

enum LauncherFiles {
    static func directory(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw LauncherFailure.unavailable }
    }
    static func read<T: Decodable>(_ type: T.Type, _ path: String) throws -> T {
        var before = stat()
        guard lstat(path, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_uid == getuid(), before.st_nlink == 1, before.st_mode & 0o077 == 0,
              before.st_size >= 0, before.st_size <= 65536 else { throw LauncherFailure.unavailable }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw LauncherFailure.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == before.st_dev, opened.st_ino == before.st_ino,
              let data = try handle.read(upToCount: 65537), data.count <= 65536 else { throw LauncherFailure.unavailable }
        return try JSONDecoder().decode(type, from: data)
    }
    static func publish(_ receipt: LauncherReceipt, _ control: String) throws {
        let pending = control + "/.launch-pending"
        let fd = open(pending, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw LauncherFailure.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); unlink(pending) }
        let data = try JSONEncoder().encode(receipt)
        guard data.count <= 65536 else { throw LauncherFailure.unavailable }
        try handle.write(contentsOf: data)
        try handle.close()
        guard renamex_np(pending, control + "/launch.json", UInt32(RENAME_EXCL)) == 0 else { throw LauncherFailure.unavailable }
    }
}

enum LauncherArguments {
    // Inspect only the known argument region, never environment strings.
    // Darwin interface: apple-oss-distributions/xnu bsd/sys/sysctl.h.
    static func matches(_ data: Data, _ expected: [String]) -> Bool {
        guard data.count >= 4, data.count <= 1048576,
              data.withUnsafeBytes({ $0.loadUnaligned(as: Int32.self) }) == expected.count else { return false }
        var offset = 4
        func take() -> Data? {
            guard offset < data.count, let end = data[offset...].firstIndex(of: 0) else { return nil }
            let result = data[offset..<end]; offset = end + 1; return result
        }
        guard take() == Data("/usr/bin/open".utf8) else { return false }
        while offset < data.count && data[offset] == 0 { offset += 1 }
        for argument in expected {
            guard !argument.contains("\0"), take() == Data(argument.utf8) else { return false }
        }
        return true
    }
    static func verify(_ pid: Int32, _ expected: [String]) throws {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var count = 0
        guard sysctl(&mib, 3, nil, &count, nil, 0) == 0, count >= 4, count <= 1048576 else { throw LauncherFailure.unavailable }
        var bytes = Data(count: count)
        defer { bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex) }
        let result = bytes.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &count, nil, 0) }
        guard result == 0, count <= bytes.count else { throw LauncherFailure.unavailable }
        bytes.count = count
        guard matches(bytes, expected) else { throw LauncherFailure.unavailable }
    }
}

func verifyLauncher(_ control: String, supervisorPID: Int32, launcherPID: Int32) throws -> String {
    try LauncherFiles.directory(control)
    let binding = try LauncherFiles.read(LauncherBinding.self, control + "/binding.json")
    try binding.validate()
    let receipt = try LauncherFiles.read(LauncherReceipt.self, control + "/launch.json")
    guard receipt.schema == "cadence/launcher/v1", receipt.observationID == binding.observationID,
          receipt.arguments == binding.arguments, receipt.launcherPID == launcherPID,
          receipt.supervisorPID == supervisorPID, receipt.launcher.pid == launcherPID,
          receipt.supervisor.pid == supervisorPID, receipt.launcher.parentPID == supervisorPID,
          receipt.launcher.executable == "/usr/bin/open",
          try LauncherIdentity.read(supervisorPID) == receipt.supervisor,
          try LauncherIdentity.read(launcherPID) == receipt.launcher else { throw LauncherFailure.unavailable }
    return binding.arguments.joined(separator: " ") + "\n"
}

func cleanupLauncher(_ control: String, supervisorPID: Int32) throws {
    alarm(5)
    try LauncherFiles.directory(control)
    let binding = try LauncherFiles.read(LauncherBinding.self, control + "/binding.json")
    try binding.validate()
    var candidates: [LauncherIdentity] = []
    if FileManager.default.fileExists(atPath: control + "/launch.json") {
        let receipt = try LauncherFiles.read(LauncherReceipt.self, control + "/launch.json")
        guard receipt.schema == "cadence/launcher/v1", receipt.observationID == binding.observationID,
              receipt.arguments == binding.arguments, receipt.supervisorPID == supervisorPID,
              receipt.launcherPID == receipt.launcher.pid, receipt.launcher.parentPID == supervisorPID,
              receipt.launcher.executable == "/usr/bin/open" else { throw LauncherFailure.unavailable }
        if kill(receipt.launcherPID, 0) != 0 {
            guard errno == ESRCH else { throw LauncherFailure.unavailable }
            return
        }
        var info = proc_bsdinfo()
        if proc_pidinfo(receipt.launcherPID, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info), info.pbi_status == UInt32(SZOMB) { return }
        let live = try LauncherIdentity.read(receipt.launcherPID)
        guard live.pid == receipt.launcher.pid, live.uid == receipt.launcher.uid,
              live.executable == receipt.launcher.executable, live.startSeconds == receipt.launcher.startSeconds,
              live.startMicroseconds == receipt.launcher.startMicroseconds,
              live.parentPID == supervisorPID || live.parentPID == 1 else { throw LauncherFailure.unavailable }
        candidates = [live]
    } else {
        // If a supervisor dies before publication, its child was never resumed.
        // Recover only a stopped system open with every exact original argument.
        var pids = [Int32](repeating: 0, count: 8192)
        let capacity = pids.count * MemoryLayout<Int32>.size
        let count = proc_listallpids(&pids, Int32(capacity))
        guard count >= 0, count < pids.count else { throw LauncherFailure.unavailable }
        for pid in pids.prefix(Int(count)) where pid > 1 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
                  info.pbi_uid == getuid(), info.pbi_status == UInt32(SSTOP),
                  info.pbi_ppid == UInt32(supervisorPID) || info.pbi_ppid == 1,
                  let live = try? LauncherIdentity.read(pid), live.executable == "/usr/bin/open" else { continue }
            if (try? LauncherArguments.verify(pid, binding.arguments)) != nil { candidates.append(live) }
        }
    }
    for candidate in candidates {
        guard try LauncherIdentity.read(candidate.pid) == candidate else { throw LauncherFailure.unavailable }
        guard kill(candidate.pid, SIGKILL) == 0 || errno == ESRCH else { throw LauncherFailure.unavailable }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while kill(candidate.pid, 0) == 0 && ProcessInfo.processInfo.systemUptime < deadline {
            var info = proc_bsdinfo()
            if proc_pidinfo(candidate.pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info), info.pbi_status == UInt32(SZOMB) { break }
            usleep(10000)
        }
        if kill(candidate.pid, 0) == 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(candidate.pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info), info.pbi_status == UInt32(SZOMB) else { throw LauncherFailure.unavailable }
        } else if errno != ESRCH { throw LauncherFailure.unavailable }
    }
}
