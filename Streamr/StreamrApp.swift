import SwiftUI
import SwiftData

@main
struct StreamrApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(for: [Playlist.self, Episode.self]) { result in
                    guard let container = try? result.get() else { return }
                    repairDownloadFlags(in: container)
                }
        }
    }

    /// On every launch, any episode whose local file exists on disk but whose
    /// isDownloaded flag is false gets corrected.  This self-heals episodes
    /// whose completion-handler save was lost due to the app being killed
    /// before URLSession delivered the background-download event.
    private func repairDownloadFlags(in container: ModelContainer) {
        Task { @MainActor in
            let context = container.mainContext
            let episodes = (try? context.fetch(FetchDescriptor<Episode>())) ?? []
            var dirty = false
            for episode in episodes {
                guard let filename = episode.localFilename, !episode.isDownloaded else { continue }
                let fileURL = DownloadManager.destinationURL(for: filename)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    episode.isDownloaded = true
                    episode.downloadProgress = 1.0
                    dirty = true
                }
            }
            if dirty { try? context.save() }
        }
    }
}
