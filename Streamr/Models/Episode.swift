import Foundation
import SwiftData

/// A single downloaded podcast-style episode.
@Model
final class Episode {
    // MARK: - Identity
    var id: UUID
    /// Title of the web page the media was downloaded from.
    var title: String
    /// The source URL string of the page the user was on when the download began.
    var sourcePageURL: String
    /// The best icon/artwork URL found on the source page (og:image, apple-touch-icon, or favicon).
    var pageIconURL: String?
    /// The direct URL of the media file.
    var mediaURL: String
    /// Local file path (relative to the app's Documents directory) after download completes.
    var localFilename: String?
    /// Date the episode was added to the queue.
    var addedAt: Date

    // MARK: - Download state
    /// Download progress 0.0 – 1.0.  1.0 = fully downloaded.
    var downloadProgress: Double
    /// Whether the file has been fully downloaded and is playable.
    var isDownloaded: Bool

    // MARK: - Playback state
    /// Position (in seconds) where the user last stopped playback.
    var playbackPosition: Double
    /// Total duration in seconds (populated after the file is available).
    var duration: Double
    /// Whether the user has finished listening to this episode.
    var isFinished: Bool
    /// The last date the user played this episode.
    var lastPlayedAt: Date?

    // MARK: - Ordering
    /// Position in the user's queue (lower = earlier in list).
    var queuePosition: Int

    // MARK: - Playlist relationship
    /// The playlist this episode belongs to.
    var playlist: Playlist?

    init(
        id: UUID = .init(),
        title: String,
        sourcePageURL: String,
        pageIconURL: String? = nil,
        mediaURL: String,
        localFilename: String? = nil,
        addedAt: Date = .now,
        downloadProgress: Double = 0,
        isDownloaded: Bool = false,
        playbackPosition: Double = 0,
        duration: Double = 0,
        isFinished: Bool = false,
        lastPlayedAt: Date? = nil,
        queuePosition: Int = 0,
        playlist: Playlist? = nil
    ) {
        self.id = id
        self.title = title
        self.sourcePageURL = sourcePageURL
        self.pageIconURL = pageIconURL
        self.mediaURL = mediaURL
        self.localFilename = localFilename
        self.addedAt = addedAt
        self.downloadProgress = downloadProgress
        self.isDownloaded = isDownloaded
        self.playbackPosition = playbackPosition
        self.duration = duration
        self.isFinished = isFinished
        self.lastPlayedAt = lastPlayedAt
        self.queuePosition = queuePosition
        self.playlist = playlist
    }

    // MARK: - Helpers

    /// Resolved URL for playback: local file if downloaded, otherwise remote.
    var playbackURL: URL? {
        if let filename = localFilename {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return docs.appendingPathComponent(filename)
        }
        return URL(string: mediaURL)
    }

    var remainingTime: Double {
        guard duration > 0 else { return 0 }
        return max(0, duration - playbackPosition)
    }

    var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, playbackPosition / duration)
    }
}
