import Foundation
import Darwin

enum LogReader {
    static let maximumBytes = 128 * 1024

    static func read(_ url: URL) -> LogSnapshot {
        do {
            // O_NONBLOCK prevents a misconfigured FIFO/device log path from hanging the app.
            let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else {
                if errno == ENOENT {
                    return LogSnapshot(text: "", message: "The log file does not exist yet. Output will appear after the job writes to it.", fileURL: url)
                }
                return LogSnapshot(text: "", message: "Cannot open this log: \(String(cString: strerror(errno)))", fileURL: url)
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                return LogSnapshot(text: "", message: "This log path is not a regular file.", fileURL: url)
            }
            let size = UInt64(max(0, info.st_size))
            let truncated = size > UInt64(maximumBytes)
            if truncated { try handle.seek(toOffset: size - UInt64(maximumBytes)) }
            var data = try handle.read(upToCount: maximumBytes) ?? Data()
            if truncated, let newline = data.firstIndex(of: 10) {
                // Drop the first partial line, but preserve a long line when no newline exists.
                data = data.suffix(from: data.index(after: newline))
            }
            let text = String(decoding: data, as: UTF8.self)
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            return LogSnapshot(text: text, message: text.isEmpty ? "No output has been written to this file yet." : nil,
                fileURL: url, modifiedAt: modified, truncated: truncated)
        } catch {
            return LogSnapshot(text: "", message: "Could not read the log: \(error.localizedDescription)", fileURL: url)
        }
    }
}
