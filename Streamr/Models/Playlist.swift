import Foundation
import SwiftData

/// A named playlist that holds an ordered collection of episodes.
@Model
final class Playlist {
    // MARK: - Identity
    var id: UUID
    var name: String
    var createdAt: Date

    // MARK: - Relationship
    /// Episodes belonging to this playlist, ordered by their `queuePosition`.
    @Relationship(deleteRule: .cascade, inverse: \Episode.playlist)
    var episodes: [Episode]

    init(
        id: UUID = .init(),
        name: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.episodes = []
    }

    // MARK: - Helpers

    /// Episodes sorted by queuePosition ascending.
    var sortedEpisodes: [Episode] {
        episodes.sorted { $0.queuePosition < $1.queuePosition }
    }

    /// Count of episodes not yet finished.
    var unfinishedCount: Int {
        episodes.filter { !$0.isFinished }.count
    }

    /// Total remaining playback time across all episodes (in seconds).
    var totalRemainingTime: Double {
        episodes.reduce(0) { $0 + $1.remainingTime }
    }
}
