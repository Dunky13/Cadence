import Foundation
import Darwin
import Security

private enum LauncherStage: String {
    case protocolInput, control, binding, appleSignature, spawn, kernelIdentity
    case initialArguments, receipt, resume, childExit, liveVerification, cleanup
}
private var launcherStage = LauncherStage.protocolInput

func superviseLauncher(_ control: String) throws -> Int32 {
    var signals = sigset_t()
    sigemptyset(&signals)
    for value in [SIGCHLD, SIGHUP, SIGINT, SIGTERM, SIGALRM] { sigaddset(&signals, value); signal(value, SIG_DFL) }
    var originalMask = sigset_t()
    guard pthread_sigmask(SIG_BLOCK, &signals, &originalMask) == 0 else { throw LauncherFailure.unavailable }
    alarm(45)
    launcherStage = .control
    try LauncherFiles.directory(control)
    launcherStage = .binding
    let binding = try LauncherFiles.read(LauncherBinding.self, control + "/binding.json")
    try binding.validate()
    launcherStage = .appleSignature
    var code: SecStaticCode?
    var requirement: SecRequirement?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: "/usr/bin/open") as CFURL, [], &code) == errSecSuccess,
          SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
          let code, let requirement, SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else { throw LauncherFailure.unavailable }
    launcherStage = .spawn
    var attr: posix_spawnattr_t?
    guard posix_spawnattr_init(&attr) == 0 else { throw LauncherFailure.unavailable }
    defer { posix_spawnattr_destroy(&attr) }
    let flags = Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
    guard posix_spawnattr_setflags(&attr, flags) == 0,
          posix_spawnattr_setsigmask(&attr, &originalMask) == 0,
          posix_spawnattr_setsigdefault(&attr, &signals) == 0 else { throw LauncherFailure.unavailable }
    var argv = binding.arguments.map { strdup($0) } + [nil]
    var environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { for value in argv + environment { if let value { free(value) } } }
    guard argv.dropLast().allSatisfy({ $0 != nil }), environment.dropLast().allSatisfy({ $0 != nil }) else { throw LauncherFailure.unavailable }
    var child: pid_t = 0
    let spawn = argv.withUnsafeMutableBufferPointer {
        posix_spawn(&child, "/usr/bin/open", nil, &attr, $0.baseAddress!, &environment)
    }
    guard spawn == 0, child > 1 else { throw LauncherFailure.unavailable }
    var reaped = false
    defer {
        if !reaped { kill(child, SIGKILL); var status: Int32 = 0; while waitpid(child, &status, 0) < 0 && errno == EINTR {} }
    }
    launcherStage = .kernelIdentity
    let launcher = try LauncherIdentity.read(child)
    let supervisor = try LauncherIdentity.read(getpid())
    guard launcher.executable == "/usr/bin/open", launcher.parentPID == supervisor.pid else { throw LauncherFailure.unavailable }
    launcherStage = .initialArguments
    try LauncherArguments.verify(child, binding.arguments)
    func cancelled() -> Int32? {
        if FileManager.default.fileExists(atPath: control + "/stop") { return 143 }
        var pending = sigset_t()
        guard sigpending(&pending) == 0 else { return 1 }
        return [SIGHUP, SIGINT, SIGTERM, SIGALRM].first { sigismember(&pending, $0) == 1 }.map { 128 + $0 }
    }
    if let status = cancelled() { return status }
    launcherStage = .receipt
    try LauncherFiles.publish(LauncherReceipt(schema: "cadence/launcher/v1", observationID: binding.observationID,
        launcherPID: child, supervisorPID: supervisor.pid, launcher: launcher, supervisor: supervisor, arguments: binding.arguments), control)
    if let status = cancelled() { return status }
    launcherStage = .resume
    guard kill(child, SIGCONT) == 0 else { throw LauncherFailure.unavailable }
    launcherStage = .childExit
    while true {
        var status: Int32 = 0
        let result = waitpid(child, &status, WNOHANG)
        if result == child {
            reaped = true
            return status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        }
        guard result == 0 || (result < 0 && errno == EINTR) else { throw LauncherFailure.unavailable }
        // Process-directed SIGCHLD need not wake this thread's sigwait.
        // Recheck the authoritative child status instead of waiting
        // indefinitely with a zombie child.
        if let status = cancelled() { return status }
        usleep(10_000)
    }
}

do {
    let values = CommandLine.arguments
    if values.count == 3, values[1] == "launch" {
        exit(try superviseLauncher(values[2]))
    } else if values.count == 5, values[1] == "verify", let supervisor = Int32(values[3]), let child = Int32(values[4]) {
        launcherStage = .liveVerification
        try FileHandle.standardOutput.write(contentsOf: Data(verifyLauncher(values[2], supervisorPID: supervisor, launcherPID: child).utf8))
    } else if values.count == 4, values[1] == "cleanup", let supervisor = Int32(values[3]), supervisor > 1 {
        launcherStage = .cleanup
        try cleanupLauncher(values[2], supervisorPID: supervisor)
    } else { throw LauncherFailure.unavailable }
} catch {
    fputs("Observer launcher identity unavailable at \(launcherStage.rawValue).\n", stderr)
    exit(1)
}
