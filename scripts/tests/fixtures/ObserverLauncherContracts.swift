import Foundation
import Darwin

enum ContractFailure: Error { case failed(Int) }

@main
struct ObserverLauncherContracts {
    static var cases = 0
    static func check(_ value: Bool) throws {
        cases += 1
        if !value { throw ContractFailure.failed(cases) }
    }
    static func run(_ executable: String, _ args: [String], environment: [String: String]? = nil, captureErrors: Bool = false) throws -> (Int32, Data) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", "alarm 8; exec @ARGV; die", "--", executable] + args
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = captureErrors ? output : FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
    static func buffer(_ args: [String], argc: Int32? = nil, path: String = "/usr/bin/open") -> Data {
        var value = argc ?? Int32(args.count)
        var data = withUnsafeBytes(of: &value) { Data($0) }
        data.append(Data(path.utf8)); data.append(contentsOf: [0, 0, 0])
        for argument in args { data.append(Data(argument.utf8)); data.append(0) }
        return data
    }
    static func suspended(_ args: [String]) throws -> Int32 {
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { throw ContractFailure.failed(cases) }
        defer { posix_spawnattr_destroy(&attr) }
        guard posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_START_SUSPENDED)) == 0 else { throw ContractFailure.failed(cases) }
        var argv = args.map { strdup($0) } + [nil]
        defer { for value in argv { if let value { free(value) } } }
        var pid: Int32 = 0
        guard argv.withUnsafeMutableBufferPointer({ posix_spawn(&pid, "/usr/bin/open", nil, &attr, $0.baseAddress!, nil) }) == 0 else { throw ContractFailure.failed(cases) }
        return pid
    }
    static func main() throws {
        umask(0o077)
        let helper = CommandLine.arguments[1]
        let workspace = URL(fileURLWithPath: CommandLine.arguments[2])
        let adapter = CommandLine.arguments[3]
        let expected = ["/usr/bin/open", "-n", "-W", "/owned/Cadence.app", "--args", "--demo", "--snapshot", "/owned/startup.png"]
        try check(LauncherArguments.matches(buffer(expected), expected))
        var withTail = buffer(expected); withTail.append(Data("UNREAD_SYNTHETIC_TAIL=value".utf8))
        try check(LauncherArguments.matches(withTail, expected))
        try check(!LauncherArguments.matches(buffer(expected, argc: 7), expected))
        try check(!LauncherArguments.matches(buffer(expected, path: "/unrelated/open"), expected))
        try check(!LauncherArguments.matches(Data(), expected))
        for index in expected.indices {
            var wrong = expected; wrong[index] += "-foreign"
            try check(!LauncherArguments.matches(buffer(wrong), expected))
        }
        try check(!LauncherArguments.matches(buffer(Array(expected.prefix(6)), argc: 8), expected))
        var mutated = buffer(expected)
        if let range = mutated.range(of: Data("--args".utf8)) { mutated[range.lowerBound] = 0 }
        try check(!LauncherArguments.matches(mutated, expected))

        for mode in ["TERM", "INT", "HUP", "KILL", "stop-product"] {
            let control = workspace.appendingPathComponent(mode)
            try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let app = control.appendingPathComponent("Cadence.app")
            let snapshot = control.appendingPathComponent("startup.png")
            try check(!FileManager.default.fileExists(atPath: app.path))
            let binding = ["copiedPath": app.path, "snapshotPath": snapshot.path, "observationID": UUID().uuidString]
            let bindingData = try JSONSerialization.data(withJSONObject: binding)
            try bindingData.write(to: control.appendingPathComponent("binding.json"))
            // Back-pressure only the CLI error for a guaranteed nonexistent target.
            let output = Pipe()
            let fd = output.fileHandleForWriting.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw ContractFailure.failed(cases) }
            let fill = [UInt8](repeating: 120, count: 1024)
            while fill.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) > 0 {}
            guard errno == EAGAIN, fcntl(fd, F_SETFL, flags) == 0 else { throw ContractFailure.failed(cases) }
            let supervisor = Process()
            // Match the Bash caller exactly; Foundation rewrites /private/var argv[0].
            supervisor.executableURL = URL(fileURLWithPath: "/bin/bash")
            supervisor.arguments = ["-c", "exec \"$CONTRACT_HELPER\" launch \"$CONTRACT_CONTROL\""]
            var launchEnvironment = ProcessInfo.processInfo.environment
            launchEnvironment["CONTRACT_HELPER"] = helper
            launchEnvironment["CONTRACT_CONTROL"] = control.path
            supervisor.environment = launchEnvironment
            supervisor.standardInput = FileHandle.nullDevice
            supervisor.standardOutput = output
            supervisor.standardError = output
            try supervisor.run()
            var receiptData: Data?
            defer {
                try? bindingData.write(to: control.appendingPathComponent("binding.json"))
                if let receiptData { try? receiptData.write(to: control.appendingPathComponent("launch.json")) }
                if supervisor.isRunning { kill(supervisor.processIdentifier, SIGKILL) }
                supervisor.waitUntilExit()
                _ = try? run(helper, ["cleanup", control.path, String(supervisor.processIdentifier)])
                try? output.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
            }
            let receiptURL = control.appendingPathComponent("launch.json")
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !FileManager.default.fileExists(atPath: receiptURL.path) && supervisor.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(1000) }
            receiptData = try Data(contentsOf: receiptURL)
            let receipt = try JSONDecoder().decode(LauncherReceipt.self, from: receiptData!)
            let child = receipt.launcherPID
            try check(receipt.supervisorPID == supervisor.processIdentifier && receipt.launcher.parentPID == supervisor.processIdentifier)
            let wanted = ["/usr/bin/open", "-n", "-W", app.path, "--args", "--demo", "--snapshot", snapshot.path]
            try check(receipt.arguments == wanted)
            usleep(30000)
            let display = try run("/bin/ps", ["-p", String(child), "-o", "command="])
            try check(display.0 == 0 && String(decoding: display.1, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) != wanted.joined(separator: " "))
            let verified = try run(helper, ["verify", control.path, String(supervisor.processIdentifier), String(child)])
            try check(verified.0 == 0 && verified.1 == Data((wanted.joined(separator: " ") + "\n").utf8))
            let wrongPID = try run(helper, ["verify", control.path, String(supervisor.processIdentifier), String(getpid())])
            try check(wrongPID.0 != 0 && wrongPID.1.isEmpty)
            var changed = binding; changed["snapshotPath"] = control.appendingPathComponent("foreign/startup.png").path
            try JSONSerialization.data(withJSONObject: changed).write(to: control.appendingPathComponent("binding.json"))
            let wrongBinding = try run(helper, ["verify", control.path, String(supervisor.processIdentifier), String(child)])
            try check(wrongBinding.0 != 0 && wrongBinding.1.isEmpty)
            try bindingData.write(to: control.appendingPathComponent("binding.json"))
            guard var object = try JSONSerialization.jsonObject(with: receiptData!) as? [String: Any] else { throw ContractFailure.failed(cases) }
            object["observationID"] = UUID().uuidString
            try JSONSerialization.data(withJSONObject: object).write(to: receiptURL)
            let wrongNonce = try run(helper, ["verify", control.path, String(supervisor.processIdentifier), String(child)])
            try check(wrongNonce.0 != 0 && wrongNonce.1.isEmpty)
            try receiptData!.write(to: receiptURL)
            if mode == "stop-product" {
                kill(supervisor.processIdentifier, SIGSTOP)
                var env = ProcessInfo.processInfo.environment
                env["OBSERVER_SCRIPT"] = adapter; env["OWNED_SUPERVISOR"] = String(supervisor.processIdentifier); env["VERIFIER"] = helper
                let command = """
                source "$OBSERVER_SCRIPT"
                launcher=$OWNED_SUPERVISOR
                observer_launcher_verifier=$VERIFIER
                launch_ui_stop_product
                [[ -z $launcher ]]
                """
                let stopped = try run("/bin/bash", ["-c", command], environment: env, captureErrors: true)
                if stopped.0 != 0 { try FileHandle.standardError.write(contentsOf: stopped.1) }
                try check(stopped.0 == 0)
            } else {
                let signal: Int32 = ["TERM": SIGTERM, "INT": SIGINT, "HUP": SIGHUP, "KILL": SIGKILL][mode]!
                kill(supervisor.processIdentifier, signal)
            }
            supervisor.waitUntilExit()
            let cleaned = try run(helper, ["cleanup", control.path, String(supervisor.processIdentifier)])
            try check(cleaned.0 == 0)
            try check((try? LauncherIdentity.read(child)) == nil)
            try check(!FileManager.default.fileExists(atPath: snapshot.path))
        }
        let control = workspace.appendingPathComponent("unpublished")
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let app = control.appendingPathComponent("Cadence.app")
        let snapshot = control.appendingPathComponent("startup.png")
        try check(!FileManager.default.fileExists(atPath: app.path))
        let binding = ["copiedPath": app.path, "snapshotPath": snapshot.path, "observationID": UUID().uuidString]
        try JSONSerialization.data(withJSONObject: binding).write(to: control.appendingPathComponent("binding.json"))
        let args = ["/usr/bin/open", "-n", "-W", app.path, "--args", "--demo", "--snapshot", snapshot.path]
        let owned = try suspended(args)
        var ownedActive = true
        var foreignOwned: Int32?
        defer {
            let remaining = (ownedActive ? [owned] : []) + (foreignOwned.map { [$0] } ?? [])
            for pid in remaining {
                kill(pid, SIGKILL)
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            }
        }
        var foreignArgs = args; foreignArgs[7] = control.appendingPathComponent("foreign/startup.png").path
        let foreign = try suspended(foreignArgs)
        foreignOwned = foreign
        // The original parent remains responsible for reaping its own child.
        let reaped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var status: Int32 = 0
            while waitpid(owned, &status, 0) < 0 && errno == EINTR {}
            reaped.signal()
        }
        let recovery = try run(helper, ["cleanup", control.path, String(getpid())])
        try check(reaped.wait(timeout: .now() + 3) == .success)
        ownedActive = false
        try check(recovery.0 == 0)
        try check((try? LauncherIdentity.read(owned)) == nil)
        try check((try? LauncherIdentity.read(foreign)) != nil)
        try Data().write(to: control.appendingPathComponent("stop"))
        let cancelled = try run(helper, ["launch", control.path])
        try check(cancelled.0 == 143)
        try check(!FileManager.default.fileExists(atPath: control.appendingPathComponent("launch.json").path))
        let afterCancellation = try run(helper, ["cleanup", control.path, String(getpid())])
        try check(afterCancellation.0 == 0 && (try? LauncherIdentity.read(foreign)) != nil)
        print("Observer launcher: \(cases) native argument/identity/cancellation contracts passed; only nonexistent app targets, no UI.")
    }
}
