import SwiftUI

/// Очередь (UI-053, PLAY-003): перестановка перетаскиванием, удаление свайпом с отменой, замок правки.
/// Внизу — перемешивание, закрыть, повтор, как на Android.
struct QueueScreen: View {
    @EnvironmentObject private var player: PlayerController
    @Environment(\.presentationMode) private var presentation

    @State private var removed: (track: Track, index: Int)?
    @State private var undoToken = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            if player.queue.isEmpty {
                Spacer()
                Text(L("ios_queue_empty")).foregroundColor(.secondary)
                Spacer()
            } else {
                list
            }
            if let r = removed { undoBar(r) }
            footer
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("queue")).font(.title3.weight(.bold))
                Text([player.queueTitle, LPlural("n_song", player.queue.count)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: { player.queueLocked.toggle() }) {
                Image(systemName: player.queueLocked ? "lock.fill" : "lock.open")
                    .frame(width: 44, height: 44)
                    .foregroundColor(player.queueLocked ? .accentColor : .secondary)
            }
            .accessibility(label: Text(L(player.queueLocked ? "ios_unlock_queue" : "ios_lock_queue")))
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(player.queue.enumerated()), id: \.offset) { index, track in
                    row(track, index: index)
                        .id(index)
                        .deleteDisabled(player.queueLocked)
                        .moveDisabled(player.queueLocked)
                }
                .onMove { source, destination in
                    if let s = source.first { player.move(from: s, to: destination) }
                }
                .onDelete { offsets in
                    guard let i = offsets.first, player.queue.indices.contains(i) else { return }
                    let t = player.queue[i]
                    player.remove(at: i)
                    removed = (t, i)
                    undoToken += 1
                    let token = undoToken
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if undoToken == token { removed = nil }
                    }
                }
            }
            .listStyle(PlainListStyle())
            .environment(\.editMode, .constant(player.queueLocked ? .inactive : .active))
            .onAppear {
                if let c = player.currentIndex { proxy.scrollTo(c, anchor: .center) }
            }
        }
    }

    private func row(_ track: Track, index: Int) -> some View {
        let isCurrent = index == player.currentIndex
        return HStack(spacing: 12) {
            ZStack {
                ArtworkView(url: track.artworkUrl, size: 44, cornerRadius: 6)
                if isCurrent {
                    Color.black.opacity(0.45).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
                    Image(systemName: player.isPlaying ? "waveform" : "pause.fill").font(.footnote).foregroundColor(.white)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.body).lineLimit(1).foregroundColor(isCurrent ? .accentColor : .primary)
                Text(track.artistNames).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(formatDuration(ms: track.durationMs)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { player.jump(to: index) }
    }

    private func undoBar(_ r: (track: Track, index: Int)) -> some View {
        HStack {
            Text(L("ios_removed_from_queue", r.track.title)).font(.footnote).lineLimit(1)
            Spacer()
            Button(L("undo")) {
                player.restore(r.track, at: r.index)
                removed = nil
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }

    private var footer: some View {
        HStack {
            Button(action: player.toggleShuffle) {
                Image(systemName: "shuffle").frame(width: 56, height: 48)
                    .foregroundColor(player.shuffle ? .accentColor : .secondary)
            }
            Spacer()
            Button(action: { presentation.wrappedValue.dismiss() }) {
                Image(systemName: "chevron.down").font(.title3).frame(width: 56, height: 48).foregroundColor(.primary)
            }
            Spacer()
            Button(action: player.cycleRepeat) {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").frame(width: 56, height: 48)
                    .foregroundColor(player.repeatMode != .off ? .accentColor : .secondary)
            }
        }
        .padding(.horizontal, 16)
        .background(Color(.secondarySystemBackground).ignoresSafeArea(edges: .bottom))
    }
}
