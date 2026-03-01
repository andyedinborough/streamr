import Foundation
import Combine

/// Intercepts navigation decisions and response MIME types inside the browser
/// to identify audio/video downloads.
struct MediaCandidate: Equatable {
    let mediaURL: URL
    let pageURL: URL
    let pageTitle: String
    /// Trimmed visible text of the source page, used to give the AI model context.
    /// Empty string when not available.
    var pageText: String = ""
}

/// MIME type prefixes that we treat as downloadable media.
private let mediaMIMEPrefixes = ["audio/", "video/"]

/// URL file extensions that strongly suggest media even without a MIME type.
private let mediaExtensions: Set<String> = [
    "mp3", "m4a", "aac", "ogg", "opus", "flac", "wav",
    "mp4", "m4v", "mov", "webm", "mkv"
]

func isMediaMIMEType(_ mimeType: String?) -> Bool {
    guard let mime = mimeType?.lowercased() else { return false }
    return mediaMIMEPrefixes.contains(where: { mime.hasPrefix($0) })
}

func isMediaURL(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return mediaExtensions.contains(ext)
}

/// Maps a MIME type string to a file extension suitable for AVFoundation.
private func fileExtension(forMIMEType mime: String) -> String? {
    switch mime.lowercased() {
    case "audio/mpeg", "audio/mp3":             return "mp3"
    case "audio/mp4", "audio/x-m4a",
         "audio/aac", "audio/x-aac":            return "m4a"
    case "audio/ogg", "audio/opus",
         "audio/x-opus+ogg":                    return "opus"
    case "audio/flac", "audio/x-flac":          return "flac"
    case "audio/wav", "audio/x-wav",
         "audio/wave":                           return "wav"
    case "video/mp4":                            return "mp4"
    case "video/x-m4v":                          return "m4v"
    case "video/quicktime":                      return "mov"
    case "video/webm":                           return "webm"
    case "video/x-matroska":                     return "mkv"
    default:                                     return nil
    }
}

/// Detects media format by reading the first few bytes (magic numbers).
/// Returns a file extension string, or nil if unrecognised.
private func fileExtension(forFileAt url: URL) -> String? {
    guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
    let bytes = Array((try? fh.read(upToCount: 12)) ?? Data())
    try? fh.close()
    guard bytes.count >= 4 else { return nil }

    // MP3: ID3 tag or sync word 0xFF 0xFB/0xF3/0xF2
    if bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33 { return "mp3" }
    if bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0 { return "mp3" }

    // M4A / MP4: ftyp box at offset 4
    if bytes.count >= 8 &&
       bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 {
        // brand bytes at offset 8
        if bytes.count >= 12 {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
            if ["M4A ", "M4B ", "mp42", "isom", "iso2", "avc1"].contains(brand) { return "m4a" }
        }
        return "mp4"
    }

    // AAC ADTS: 0xFF 0xF1 or 0xFF 0xF9
    if bytes[0] == 0xFF && (bytes[1] == 0xF1 || bytes[1] == 0xF9) { return "m4a" }

    // OGG (Vorbis/Opus): OggS
    if bytes[0] == 0x4F && bytes[1] == 0x67 && bytes[2] == 0x67 && bytes[3] == 0x53 { return "opus" }

    // FLAC
    if bytes[0] == 0x66 && bytes[1] == 0x4C && bytes[2] == 0x61 && bytes[3] == 0x43 { return "flac" }

    // WAV: RIFF....WAVE
    if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 { return "wav" }

    return nil
}

// MARK: - Download Manager

/// Manages foreground URLSession downloads and reports progress/completion.
/// A foreground session is used deliberately: the media URLs are signed CDN
/// links with short expiry windows, so they must start immediately and cannot
/// be deferred by the OS the way background sessions are.
@MainActor
final class DownloadManager: NSObject, ObservableObject {

    static let shared = DownloadManager()

    @Published var activeDownloads: [UUID: Double] = [:]   // episodeID → progress 0–1

    private var session: URLSession!

    // taskIDs is accessed from both the URLSession delegate queue and MainActor.
    // We opt out of actor-isolation and use NSLock to guard all accesses manually.
    private let lock = NSLock()
    nonisolated(unsafe) private var taskIDs: [URLSessionDownloadTask: UUID] = [:]  // task → episodeID
    private var completionHandlers: [UUID: (URL?) -> Void] = [:]

    override private init() {
        super.init()
        // Foreground session — delegates called on a background serial queue.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600   // 1 h max for large files
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func download(episode: Episode, completion: @escaping (URL?) -> Void) {
        guard let url = URL(string: episode.mediaURL) else {
            completion(nil)
            return
        }
        activeDownloads[episode.id] = 0
        completionHandlers[episode.id] = completion

        let task = session.downloadTask(with: url)

        lock.lock()
        taskIDs[task] = episode.id
        lock.unlock()

        task.resume()
    }

    func cancel(episodeID: UUID) {
        lock.lock()
        let task = taskIDs.first(where: { $0.value == episodeID })?.key
        if let task { taskIDs.removeValue(forKey: task) }
        lock.unlock()

        task?.cancel()
        activeDownloads.removeValue(forKey: episodeID)
        completionHandlers.removeValue(forKey: episodeID)
    }

    // MARK: - File helpers

    nonisolated static func destinationURL(for filename: String) -> URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten written: Int64,
        totalBytesExpectedToWrite expected: Int64
    ) {
        guard expected > 0 else { return }
        let progress = Double(written) / Double(expected)
        lock.lock()
        let id = taskIDs[downloadTask]
        lock.unlock()
        guard let id else { return }
        Task { @MainActor [weak self] in
            self?.activeDownloads[id] = progress
        }
    }

    /// IMPORTANT: `location` is a temporary file that URLSession deletes as soon
    /// as this method returns.  The file move MUST happen synchronously here on
    /// the delegate queue — before we dispatch anything to MainActor.
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let id = taskIDs[downloadTask]
        lock.unlock()
        guard let id else { return }

        // Determine the correct file extension:
        // 1. Read magic bytes from the downloaded file (most reliable)
        // 2. Fall back to MIME type from HTTP response headers
        // 3. Fall back to the extension in the original request URL
        let mime = (downloadTask.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?
            .components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespaces)
            ?? downloadTask.response?.mimeType
            ?? ""
        let urlExt = downloadTask.originalRequest?.url?.pathExtension.lowercased() ?? ""

        let ext: String
        if let magic = fileExtension(forFileAt: location) {
            ext = magic
        } else if let mimeExt = fileExtension(forMIMEType: mime) {
            ext = mimeExt
        } else if !urlExt.isEmpty {
            ext = urlExt
        } else {
            ext = "mp3"
        }

        let filename = id.uuidString + "." + ext
        let dest = DownloadManager.destinationURL(for: filename)
        print("[DownloadManager] MIME='\(mime)' urlExt='\(urlExt)' magic=\(fileExtension(forFileAt: location) ?? "nil") → ext='\(ext)' dest=\(dest.lastPathComponent)")

        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            print("[DownloadManager] Saved \(dest.lastPathComponent)")
        } catch {
            print("[DownloadManager] Move failed: \(error)")
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.completionHandlers[id]?(nil)
                self.cleanup(task: downloadTask, id: id)
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.activeDownloads.removeValue(forKey: id)
            self.completionHandlers[id]?(dest)
            self.cleanup(task: downloadTask, id: id)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error, let downloadTask = task as? URLSessionDownloadTask else { return }
        lock.lock()
        let id = taskIDs[downloadTask]
        lock.unlock()
        guard let id else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            print("[DownloadManager] Task failed: \(error)")
            self.completionHandlers[id]?(nil)
            self.cleanup(task: downloadTask, id: id)
        }
    }

    // Must be called on MainActor.
    private func cleanup(task: URLSessionDownloadTask, id: UUID) {
        lock.lock()
        taskIDs.removeValue(forKey: task)
        lock.unlock()
        completionHandlers.removeValue(forKey: id)
        activeDownloads.removeValue(forKey: id)
    }
}
