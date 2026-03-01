import SwiftUI
import SwiftData

// MARK: - Playlist List View

/// Root view — shows all playlists.  Tap to open, swipe to delete, + to create.
struct PlaylistListView: View {
    @Query(sort: \Playlist.createdAt) private var playlists: [Playlist]
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var playerVM: PlayerViewModel

    @State private var showNewPlaylistAlert = false
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationStack {
            Group {
                if playlists.isEmpty {
                    emptyState
                } else {
                    playlistList
                }
            }
            .navigationTitle("Streamr")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newPlaylistName = ""
                        showNewPlaylistAlert = true
                    } label: {
                        Label("New Playlist", systemImage: "plus.circle.fill")
                    }
                }
            }
            .alert("New Playlist", isPresented: $showNewPlaylistAlert) {
                TextField("Name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) { }
                Button("Create") { createPlaylist() }
                    .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
            } message: {
                Text("Enter a name for your new playlist.")
            }
            .modifier(MiniPlayerInsetModifier(episode: playerVM.currentEpisode))
        }
    }

    // MARK: - List

    private var playlistList: some View {
        List {
            ForEach(playlists) { playlist in
                NavigationLink {
                    QueueView(playlist: playlist)
                } label: {
                    PlaylistRow(playlist: playlist)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            .onDelete(perform: deletePlaylists)
        }
        .listStyle(.plain)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note.list")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("No Playlists Yet")
                .font(.title3.bold())
            Text("Tap **+** to create your first playlist.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
            Button {
                newPlaylistName = ""
                showNewPlaylistAlert = true
            } label: {
                Label("Create Playlist", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func createPlaylist() {
        let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let playlist = Playlist(name: name)
        modelContext.insert(playlist)
        try? modelContext.save()
    }

    private func deletePlaylists(at offsets: IndexSet) {
        let toDelete = offsets.map { playlists[$0] }
        for playlist in toDelete {
            // Stop player if an episode from this playlist is currently playing.
            if let current = playerVM.currentEpisode,
               playlist.episodes.contains(where: { $0.id == current.id }) {
                playerVM.stop()
            }
            // Delete local files for all episodes in this playlist.
            for episode in playlist.episodes {
                if let filename = episode.localFilename {
                    let url = DownloadManager.destinationURL(for: filename)
                    try? FileManager.default.removeItem(at: url)
                }
            }
            // SwiftData cascades and deletes all episodes automatically.
            modelContext.delete(playlist)
        }
        try? modelContext.save()
    }
}

// MARK: - Playlist Row

struct PlaylistRow: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: "music.note.list")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 20, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(.body.bold())
                    .lineLimit(1)

                let count = playlist.episodes.count
                let unfinished = playlist.unfinishedCount
                Group {
                    if count == 0 {
                        Text("No episodes")
                    } else if unfinished == 0 {
                        Text("\(count) episode\(count == 1 ? "" : "s") · all played")
                    } else {
                        Text("\(unfinished) episode\(unfinished == 1 ? "" : "s") remaining")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}
