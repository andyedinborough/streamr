import SwiftUI
import SwiftData

// MARK: - Queue (Playlist episode list) View

struct QueueView: View {
    /// The playlist whose episodes are shown.
    @Bindable var playlist: Playlist

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var playerVM: PlayerViewModel
    @State private var showBrowser = false

    /// Derive sorted episodes directly from the observed playlist model.
    private var episodes: [Episode] {
        playlist.sortedEpisodes
    }

    var body: some View {
        Group {
            if episodes.isEmpty {
                emptyState
            } else {
                episodeList
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showBrowser = true
                } label: {
                    Label("Add Episode", systemImage: "plus.circle.fill")
                }
            }
        }
        .sheet(isPresented: $showBrowser) {
            BrowserSheet(playlist: playlist)
        }
        .modifier(MiniPlayerInsetModifier(episode: playerVM.currentEpisode))
    }

    // MARK: - Episode list

    private var episodeList: some View {
        List {
            ForEach(episodes) { episode in
                Button {
                    playerVM.play(episode: episode)
                } label: {
                    EpisodeRow(episode: episode)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            .onDelete(perform: deleteEpisodes)
            .onMove(perform: moveEpisodes)
        }
        .listStyle(.plain)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("No episodes yet")
                .font(.title3.bold())
            Text("Tap **+** to open the browser and add episodes.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
            Button {
                showBrowser = true
            } label: {
                Label("Browse & Add", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - List actions

    private func deleteEpisodes(at offsets: IndexSet) {
        let toDelete = offsets.map { episodes[$0] }
        let deletingCurrentEpisode = toDelete.contains { $0.id == playerVM.currentEpisode?.id }
        for episode in toDelete {
            if let filename = episode.localFilename {
                let url = DownloadManager.destinationURL(for: filename)
                try? FileManager.default.removeItem(at: url)
            }
            modelContext.delete(episode)
        }
        try? modelContext.save()
        // Stop the player if the playing episode was deleted, or the playlist is now empty.
        let remainingCount = episodes.count - toDelete.count
        if deletingCurrentEpisode || remainingCount == 0 {
            playerVM.stop()
        }
    }

    private func moveEpisodes(from source: IndexSet, to destination: Int) {
        var reordered = episodes
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, episode) in reordered.enumerated() {
            episode.queuePosition = index
        }
        try? modelContext.save()
    }
}

// MARK: - Episode Row

struct EpisodeRow: View {
    let episode: Episode
    @EnvironmentObject private var playerVM: PlayerViewModel
    @ObservedObject private var downloadMgr = DownloadManager.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Status icon
            statusIcon
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.body.bold())
                    .lineLimit(2)

                Text(episode.sourcePageURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // Progress / download bar
                progressArea
            }
        }
        .opacity(episode.isFinished ? 0.5 : 1)
    }

    // MARK: Status icon

    @ViewBuilder
    private var statusIcon: some View {
        if let iconURLString = episode.pageIconURL,
           let iconURL = URL(string: iconURLString) {
            // Artwork thumbnail with a small state badge overlaid bottom-right.
            AsyncImage(url: iconURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .bottomTrailing) {
                            stateBadge
                        }
                        .opacity(episode.isFinished ? 0.5 : 1)
                default:
                    plainIcon
                }
            }
        } else {
            plainIcon
        }
    }

    /// Small badge shown over the artwork thumbnail.
    @ViewBuilder
    private var stateBadge: some View {
        ZStack {
            Circle()
                .fill(.regularMaterial)
                .frame(width: 18, height: 18)
            Image(systemName: iconName)
                .foregroundStyle(iconForeground)
                .font(.system(size: 9, weight: .bold))
        }
        .offset(x: 4, y: 4)
    }

    /// Fallback when no artwork URL is available.
    @ViewBuilder
    private var plainIcon: some View {
        ZStack {
            Circle()
                .fill(iconBackground)
            Image(systemName: iconName)
                .foregroundStyle(iconForeground)
                .font(.system(size: 16, weight: .semibold))
        }
    }

    private var iconName: String {
        if episode.isFinished          { return "checkmark" }
        if !episode.isDownloaded {
            let p = downloadMgr.activeDownloads[episode.id]
            return p != nil ? "arrow.down" : "icloud.and.arrow.down"
        }
        if playerVM.currentEpisode?.id == episode.id && playerVM.isPlaying {
            return "pause.fill"
        }
        return "play.fill"
    }

    private var iconBackground: Color {
        episode.isFinished ? Color(.systemGray5) : Color.accentColor.opacity(0.15)
    }

    private var iconForeground: Color {
        episode.isFinished ? .secondary : Color.accentColor
    }

    // MARK: Progress

    @ViewBuilder
    private var progressArea: some View {
        if let dlProgress = downloadMgr.activeDownloads[episode.id], !episode.isDownloaded {
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: dlProgress)
                    .tint(Color.accentColor)
                Text("Downloading \(Int(dlProgress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if episode.isDownloaded && episode.duration > 0 {
            HStack(spacing: 8) {
                ProgressView(value: episode.progressFraction)
                    .tint(episode.isFinished ? .secondary : Color.accentColor)
                Text(episode.isFinished ? "Played" : timeRemainingString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if episode.isDownloaded {
            Text("Ready to play")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Text("Waiting to download…")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var timeRemainingString: String {
        let r = episode.remainingTime
        if r <= 0 { return "" }
        let mins = Int(r) / 60
        let secs = Int(r) % 60
        if mins >= 60 {
            return "\(mins / 60)h \(mins % 60)m left"
        }
        return "\(mins)m \(secs)s left"
    }
}

// MARK: - Browser Sheet (wraps BrowserView with a dismiss button)

struct BrowserSheet: View {
    let playlist: Playlist
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BrowserView(playlist: playlist)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

// MARK: - Conditional mini-player inset

/// Only adds the safeAreaInset when there is a current episode.
/// Using a ViewModifier avoids the blank spacing that .safeAreaInset
/// reserves even when its content closure returns EmptyView.
struct MiniPlayerInsetModifier: ViewModifier {
    let episode: Episode?
    func body(content: Content) -> some View {
        if let episode {
            content.safeAreaInset(edge: .bottom) {
                MiniPlayerBar(episode: episode)
            }
        } else {
            content
        }
    }
}
