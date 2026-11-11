import SwiftUI

/// Полноэкранный плеер (UI-052). Компоновка — как `ui/player/Player.kt`:
/// шапка «Сейчас играет», обложка, название с кнопками справа, ползунок, три кнопки управления,
/// внизу ряд: очередь, таймер сна, перемешивание, текст, повтор, меню.
struct PlayerScreen: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var likes: LikeManager
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.presentationMode) private var presentation

    @State private var scrub: Double?
    @State private var showQueue = false
    @State private var showSleep = false
    @State private var showSources = false
    @State private var showLyrics = false
    @State private var shareItems: [Any]?

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                Spacer(minLength: 8)
                if showLyrics {
                    LyricsView().frame(height: max(120, min(geo.size.width - 48, geo.size.height * 0.46)))
                } else {
                    artwork(side: min(geo.size.width - 48, geo.size.height * 0.46))
                }
                Spacer(minLength: 12)
                titleRow
                slider.padding(.top, 14)
                controls.padding(.top, 10)
                qualityLine.padding(.top, 10)
                Spacer(minLength: 8)
                bottomBar
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .sheet(isPresented: $showQueue) {
            QueueScreen().environmentObject(player)
        }
        .background(EmptyView().sheet(isPresented: $showSources) {
            SourcePickerScreen().environmentObject(player)
        })
        .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) {
            ShareSheet(items: shareItems ?? [])
        }
        .overlay(showSleep ? SleepTimerDialog(isPresented: $showSleep).environmentObject(player) : nil)
        .onChange(of: player.current == nil) { empty in
            if empty { presentation.wrappedValue.dismiss() }
        }
        .onAppear { if let t = player.current { likes.refresh([t]) } }
        .onChange(of: player.current?.id) { _ in
            if let t = player.current { likes.refresh([t]) }
        }
    }

    // MARK: - Шапка

    private var header: some View {
        HStack {
            Button(action: { presentation.wrappedValue.dismiss() }) {
                Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
            }
            Spacer()
            VStack(spacing: 2) {
                Text(L("now_playing")).font(.caption.weight(.semibold)).foregroundColor(.secondary)
                if let title = player.queueTitle, !title.isEmpty {
                    Text(title).font(.footnote.weight(.semibold)).lineLimit(1)
                }
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .foregroundColor(.primary)
        .padding(.horizontal, -12)
        .padding(.top, 6)
    }

    // MARK: - Обложка

    private func artwork(side: CGFloat) -> some View {
        ArtworkView(url: player.current?.artworkUrl, size: max(120, side), cornerRadius: 16)
            .shadow(color: Color.black.opacity(0.35), radius: 16, y: 8)
            .id(player.current?.artworkUrl ?? "")
            .gesture(DragGesture(minimumDistance: 30).onEnded { g in
                guard abs(g.translation.width) > abs(g.translation.height) else { return }
                if g.translation.width < -50 { player.skipNext() }
                if g.translation.width > 50 { player.skipPrevious() }
            })
            .onTapGesture(count: 2) { player.togglePlayPause() }
    }

    // MARK: - Название и кнопки справа

    private var titleRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.current?.title ?? "")
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                    .onLongPressGesture { copy(player.current?.title) }
                Text(player.current?.artistNames ?? "")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .onLongPressGesture { copy(player.current?.artistNames) }
            }
            Spacer(minLength: 0)
            Button(action: toggleLike) {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(Circle())
                    .foregroundColor(isLiked ? .red : .primary)
            }
            roundButton("square.and.arrow.up", action: share)
            downloadButton
            Menu {
                moreMenu
            } label: {
                roundLabel("ellipsis")
            }
        }
    }

    @ViewBuilder private var downloadButton: some View {
        if let t = player.current {
            switch downloads.states[t.id] {
            case .done:
                Button(action: { downloads.remove([t.id]) }) { roundLabel("arrow.down.circle.fill") }
            case .queued, .resolving:
                Button(action: { downloads.cancel(t.id) }) { roundLabel("xmark") }
            case .downloading(let p):
                Button(action: { downloads.cancel(t.id) }) {
                    Text("\(Int(p * 100))%").font(.caption2.monospacedDigit())
                        .frame(width: 42, height: 42).background(Color.secondary.opacity(0.2)).clipShape(Circle()).foregroundColor(.primary)
                }
            default:
                Button(action: { downloads.download([t]) }) { roundLabel("arrow.down.to.line") }
            }
        }
    }

    private func roundLabel(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 42, height: 42)
            .background(Color.secondary.opacity(0.2))
            .clipShape(Circle())
            .foregroundColor(.primary)
    }

    private func roundButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { roundLabel(symbol) }
    }

    private var isLiked: Bool { player.current.map(likes.isLiked) ?? false }

    private func toggleLike() {
        guard let t = player.current else { return }
        likes.toggle(t)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Закрывает плеер и открывает экран альбома или артиста.
    private func open(_ target: AppLinks.Target) {
        presentation.wrappedValue.dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { env.linkTarget = target }
    }

    @ViewBuilder private var moreMenu: some View {
        if let t = player.current {
            if let albumId = t.albumId, !albumId.isEmpty {
                Button(action: { open(AppLinks.Target(kind: .album, id: albumId, title: t.albumName, by: nil)) }) {
                    Label(L("view_album"), systemImage: "square.stack")
                }
            }
            ForEach(t.artists.filter { !($0.id ?? "").isEmpty }, id: \.self) { a in
                Button(action: { open(AppLinks.Target(kind: .artist, id: a.id ?? "", title: a.name, by: nil)) }) {
                    Label(t.artists.count > 1 ? a.name : L("view_artist"), systemImage: "person")
                }
            }
            Button(action: {
                presentation.wrappedValue.dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { env.addToPlaylist = TrackBatch(tracks: [t]) }
            }) {
                Label(L("add_to_playlist"), systemImage: "text.badge.plus")
            }
            Button(action: toggleLike) {
                Label(L(isLiked ? "action_remove_like" : "action_like"), systemImage: isLiked ? "heart.slash" : "heart")
            }
        }
        Button(action: share) { Label(L("share"), systemImage: "square.and.arrow.up") }
        Button(action: { showSources = true }) { Label(L("audio_source_choose"), systemImage: "antenna.radiowaves.left.and.right") }
        Button(action: { showSleep = true }) { Label(L("sleep_timer"), systemImage: "moon.zzz") }
        Button(action: { showQueue = true }) { Label(L("queue"), systemImage: "list.bullet") }
        Button(action: { player.clearQueue() }) { Label(L("ios_clear_queue"), systemImage: "trash") }
    }

    private func copy(_ text: String?) {
        guard let text = text, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func share() {
        guard let t = player.current else { return }
        shareItems = [AppLinks.trackLink(mediaId: t.id, title: t.title, by: t.artistNames) ?? "\(t.artistNames) — \(t.title)"]
    }

    // MARK: - Ползунок

    private var slider: some View {
        let total = max(player.duration, 1)
        return VStack(spacing: 2) {
            Slider(value: Binding(get: { min(scrub ?? player.position, total) }, set: { scrub = $0 }), in: 0...total) { editing in
                if !editing, let s = scrub {
                    player.seek(to: s)
                    // Держим значение, пока плеер не доложит новую позицию.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { scrub = nil }
                }
            }
            HStack {
                Text(formatDuration(ms: Int((scrub ?? player.position) * 1000)))
                Spacer()
                Text(formatDuration(ms: Int(player.duration * 1000)))
            }
            .font(.caption.monospacedDigit())
            .foregroundColor(.secondary)
        }
    }

    // MARK: - Управление

    private var controls: some View {
        HStack(spacing: 12) {
            Button(action: player.skipPrevious) {
                Image(systemName: "backward.end.fill").font(.title2)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            }
            Button(action: player.togglePlayPause) {
                ZStack {
                    if player.isLoading {
                        ProgressView().progressViewStyle(CircularProgressViewStyle(tint: Color(.systemBackground)))
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 64)
                .foregroundColor(Color(.systemBackground))
                .background(Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: player.isPlaying ? 20 : 32, style: .continuous))
                .animation(.easeInOut(duration: 0.2), value: player.isPlaying)
            }
            .layoutPriority(1)
            Button(action: player.skipNext) {
                Image(systemName: "forward.end.fill").font(.title2)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            }
            .disabled(!player.hasNext)
        }
        .foregroundColor(.primary)
    }

    /// Откуда идёт звук и в каком качестве; при ошибке — её текст.
    private var qualityLine: some View {
        Group {
            if let error = player.errorText {
                Text(error).foregroundColor(.red)
            } else if player.servingLocal, let s = player.servingStream {
                Text("\(L("ios_downloaded")) · \(s.codecs.hasPrefix("mp4a") ? "AAC" : s.codecs.uppercased()) · \(s.bitrate / 1000) kbps")
                    .foregroundColor(.secondary)
            } else if let m = player.serving, let s = player.servingStream {
                Text("\(m.provider.displayName) · \(s.codecs.hasPrefix("mp4a") ? "AAC" : s.codecs.uppercased()) · \(s.bitrate / 1000) kbps")
                    .foregroundColor(.secondary)
            } else if player.isLoading {
                Text(L("ios_searching_audio")).foregroundColor(.secondary)
            } else {
                Text(" ")
            }
        }
        .font(.caption)
        .lineLimit(1)
        .contentShape(Rectangle())
        .onTapGesture { if player.current != nil { showSources = true } }
    }

    // MARK: - Нижний ряд (как свёрнутая очередь на Android)

    private var bottomBar: some View {
        HStack {
            barButton("list.bullet", active: false) { showQueue = true }
            Spacer()
            barButton(player.sleepTimerActive ? "moon.zzz.fill" : "moon.zzz", active: player.sleepTimerActive) {
                if player.sleepTimerActive { player.cancelSleepTimer() } else { showSleep = true }
            }
            Spacer()
            barButton("shuffle", active: player.shuffle) { player.toggleShuffle() }
            Spacer()
            barButton(showLyrics ? "quote.bubble.fill" : "quote.bubble", active: showLyrics) { showLyrics.toggle() }
            Spacer()
            barButton(player.repeatMode == .one ? "repeat.1" : "repeat", active: player.repeatMode != .off) { player.cycleRepeat() }
            Spacer()
            Menu {
                moreMenu
            } label: {
                Image(systemName: "ellipsis").rotationEffect(.degrees(90)).font(.system(size: 18)).frame(width: 44, height: 44)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, -8)
    }

    private func barButton(_ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: active ? .bold : .regular))
                .frame(width: 44, height: 44)
                .foregroundColor(active ? .accentColor : .secondary)
        }
    }
}

/// Диалог таймера сна (PLAY-014): ползунок 5–120 минут, «Конец песни», значение по умолчанию.
struct SleepTimerDialog: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var env: AppEnvironment
    @State private var minutes: Double = 30

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { isPresented = false }
            VStack(spacing: 14) {
                Image(systemName: "moon.zzz").font(.title2)
                Text(L("sleep_timer")).font(.headline)
                Text(LPlural("minute", Int(minutes))).font(.title3.monospacedDigit())
                Slider(value: $minutes, in: 5...120, step: 5)
                HStack {
                    Button(L("set_as_default")) {
                        env.prefs.settings.set(PK.sleepTimerDefault, Float(minutes))
                    }
                    Spacer()
                    Button(L("end_of_song")) {
                        player.startSleepTimerEndOfTrack()
                        isPresented = false
                    }
                }
                .font(.footnote)
                HStack(spacing: 24) {
                    Spacer()
                    Button(L("cancel")) { isPresented = false }
                    Button("OK") {
                        player.startSleepTimer(minutes: Int(minutes))
                        isPresented = false
                    }
                    .font(.body.weight(.semibold))
                }
            }
            .padding(20)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 32)
        }
        .onAppear { minutes = Double(env.prefs.settings.get(PK.sleepTimerDefault) ?? 30) }
    }
}
