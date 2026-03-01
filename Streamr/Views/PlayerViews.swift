import SwiftUI

// MARK: - Mini Player Bar (persistent bottom strip)

struct MiniPlayerBar: View {
    let episode: Episode
    @EnvironmentObject private var playerVM: PlayerViewModel
    @State private var showFullPlayer = false

    var body: some View {
        HStack(spacing: 12) {
            // Episode info
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)

                if episode.duration > 0 {
                    ProgressView(value: episode.progressFraction)
                        .tint(Color.accentColor)
                }
            }

            Spacer()

            // Skip back 15s
            Button {
                playerVM.skip(by: -15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.title3)
            }

            // Play / Pause
            Button {
                playerVM.togglePlayPause()
            } label: {
                Image(systemName: playerVM.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 36, height: 36)
            }

            // Skip forward 30s
            Button {
                playerVM.skip(by: 30)
            } label: {
                Image(systemName: "goforward.30")
                    .font(.title3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            showFullPlayer = true
        }
        .sheet(isPresented: $showFullPlayer) {
            FullPlayerView(episode: episode)
        }
    }
}

// MARK: - Full Player View

struct FullPlayerView: View {
    let episode: Episode
    @EnvironmentObject private var playerVM: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Artwork placeholder
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(
                        colors: [Color.accentColor.opacity(0.6), Color.accentColor.opacity(0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 240, height: 240)
                    .overlay {
                        Image(systemName: "waveform")
                            .font(.system(size: 64))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .shadow(radius: 12)

                // Title + source
                VStack(spacing: 4) {
                    Text(episode.title)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                        .lineLimit(3)

                    if let host = URL(string: episode.sourcePageURL)?.host() {
                        Text(host)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                // Scrubber
                if episode.duration > 0 {
                    scrubber
                }

                // Controls
                controls

                // Playback rate
                rateSelector

                Spacer()
            }
            .padding(24)
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Scrubber

    @State private var isDragging = false
    @State private var dragValue: Double = 0

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: isDragging ? $dragValue : .init(
                    get: { playerVM.currentTime },
                    set: { playerVM.seek(to: $0) }
                ),
                in: 0...max(1, episode.duration),
                onEditingChanged: { editing in
                    isDragging = editing
                    if !editing {
                        playerVM.seek(to: dragValue)
                    } else {
                        dragValue = playerVM.currentTime
                    }
                }
            )

            HStack {
                Text(formatTime(isDragging ? dragValue : playerVM.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("-" + formatTime(episode.duration - (isDragging ? dragValue : playerVM.currentTime)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 36) {
            Button {
                playerVM.skip(by: -15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 28))
            }

            Button {
                playerVM.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 64, height: 64)
                    Image(systemName: playerVM.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                }
            }

            Button {
                playerVM.skip(by: 30)
            } label: {
                Image(systemName: "goforward.30")
                    .font(.system(size: 28))
            }
        }
    }

    // MARK: Rate selector

    private var rateSelector: some View {
        HStack(spacing: 8) {
            ForEach([0.75, 1.0, 1.25, 1.5, 2.0] as [Float], id: \.self) { rate in
                Button {
                    playerVM.setRate(rate)
                } label: {
                    Text(rateLabel(rate))
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(playerVM.playbackRate == rate ? Color.accentColor : Color(.systemGray5))
                        .foregroundStyle(playerVM.playbackRate == rate ? .white : .primary)
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: Helpers

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func rateLabel(_ rate: Float) -> String {
        rate == 1.0 ? "1×" : String(format: "%.2g×", rate)
    }
}
