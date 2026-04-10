import Foundation

/// Append-only JSONL writer for today's `.mow` file, with support for
/// daily rotation (gzip yesterday's file + open today's).
///
/// **NOT thread-safe.** Serialization is the EventCoordinator actor's
/// responsibility. This class owns a single `FileHandle` in append mode
/// and writes one line per call to `append(line:)`.
///
/// File layout in `directory`:
///   - `YYYY-MM-DD.mow`     — today, plain JSONL, append-only
///   - `YYYY-MM-DD.mow.gz`  — older days, gzipped by `rotate(toNewDate:)`
final class EventLog {
    private let directory: URL
    private var fileHandle: FileHandle
    private(set) var currentDate: String

    init(directory: URL) throws {
        self.directory = directory
        self.currentDate = Self.localDateString(for: Date())
        let url = Self.fileURL(directory: directory, date: currentDate)

        if !FileManager.default.fileExists(atPath: url.path) {
            try Self.createFileWithHeader(at: url, date: currentDate)
        }

        self.fileHandle = try FileHandle(forWritingTo: url)
        try fileHandle.seekToEnd()
    }

    /// Append one JSON object as a line. Caller passes the encoded
    /// bytes; this method adds the trailing newline.
    ///
    /// IMPORTANT: combines `line + \n` into a **single** `write()`
    /// syscall. Splitting it into two writes (one for the JSON, one
    /// for the newline) is unsafe under O_APPEND if two miniowl
    /// processes have the same file open — the writes can interleave
    /// at byte boundaries and corrupt the log with stray fragments
    /// like a lone `}` on its own line. One write = one atomic append.
    func append(line: Data) throws {
        var withNewline = line
        withNewline.append(0x0A)
        try fileHandle.write(contentsOf: withNewline)
    }

    /// If the local date has ticked over, returns the new date string.
    /// Otherwise nil. Cheap — formats the current `Date` and compares.
    func checkRotation() -> String? {
        let today = Self.localDateString(for: Date())
        return today != currentDate ? today : nil
    }

    /// Close the current file, gzip it, and open a fresh file for
    /// `newDate`. Called by EventCoordinator when it detects a date
    /// change. Not thread-safe — callers serialize this.
    func rotate(toNewDate newDate: String) throws {
        try fileHandle.close()

        let oldURL = Self.fileURL(directory: directory, date: currentDate)
        // Only gzip if it still exists — a prior failed rotation may
        // have already produced the .gz.
        if FileManager.default.fileExists(atPath: oldURL.path) {
            do {
                try Self.gzipInPlace(url: oldURL)
            } catch {
                // Gzip failure shouldn't kill the whole app — log and
                // continue. Uncompressed file stays on disk; next run
                // can retry.
                fputs("miniowl: gzip failed for \(oldURL.lastPathComponent): \(error)\n", stderr)
            }
        }

        self.currentDate = newDate
        let newURL = Self.fileURL(directory: directory, date: newDate)
        if !FileManager.default.fileExists(atPath: newURL.path) {
            try Self.createFileWithHeader(at: newURL, date: newDate)
        }

        self.fileHandle = try FileHandle(forWritingTo: newURL)
        try fileHandle.seekToEnd()
    }

    deinit {
        try? fileHandle.close()
    }

    // MARK: - Helpers

    private static func fileURL(directory: URL, date: String) -> URL {
        return directory.appendingPathComponent("\(date).mow")
    }

    private static func createFileWithHeader(at url: URL, date: String) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let header: [String: Any] = [
            "v": 1,
            "d": date,
            "tz": TimeZone.current.identifier,
            "start": nowMs(),
        ]
        let headerData = try JSONSerialization.data(
            withJSONObject: header,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        var line = headerData
        line.append(0x0A)
        try line.write(to: url, options: .atomic)
    }

    private static func localDateString(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    /// Shell out to `/usr/bin/gzip` to compress the file in place. This
    /// is the least-code path to real gzip format — macOS's Foundation
    /// `Compression` framework produces zlib/deflate wrapper bytes,
    /// which aren't `.gz`-compatible without hand-rolling the gzip
    /// header and CRC32 trailer.
    ///
    /// `/usr/bin/gzip -f <file>` replaces `file` with `file.gz`.
    private static func gzipInPlace(url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-f", url.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw EventLogError.gzipFailed(status: process.terminationStatus)
        }
    }
}

enum EventLogError: Error {
    case gzipFailed(status: Int32)
}
