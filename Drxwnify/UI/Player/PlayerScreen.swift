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
    @State private var showMenu = false

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
                controls.padding(.top, 14)
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
        .background(EmptyView().sheet(isPresented: $showMenu) {
            if let t = player.current {
                TrackMenuSheet(track: t, isCurrent: true, navigate: { open($0) },
                               addToPlaylist: { open(nil) { env.addToPlaylist = TrackBatch(tracks: [t]) } },
                               changeVersion: { showSources = true })
                    .environmentObject(player)
                    .environmentObject(likes)
                    .environmentObject(downloads)
                    .modifier(MediumSheet())
            }
        })
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
            VStack(spacing: 3) {
                Text(L("now_playing")).font(.headline)
                qualityLine
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
            roundButton("arrowshape.turn.up.right", action: share)
            downloadButton
            Button(action: toggleLike) {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundColor(isLiked ? .red : .primary)
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
                        .frame(width: 46, height: 46).background(Color.secondary.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)).foregroundColor(.primary)
                }
            default:
                Button(action: { downloads.download([t]) }) { roundLabel("arrow.down.to.line") }
            }
        }
    }

    private func roundLabel(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 46, height: 46)
            .background(Color.secondary.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    /// Закрывает плеер и открывает экран альбома или артиста (или выполняет `then`).
    private func open(_ target: AppLinks.Target?, then: (() -> Void)? = nil) {
        presentation.wrappedValue.dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            if let target = target { env.linkTarget = target }
            then?()
        }
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
                    .frame(width: 70, height: 70)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(Circle())
            }
            Button(action: player.togglePlayPause) {
                ZStack {
                    if player.isLoading {
                        ProgressView().progressViewStyle(CircularProgressViewStyle(tint: Color(.systemBackground)))
                    } else {
                        HStack(spacing: 10) {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                            Text(L(player.isPlaying ? "pause" : "play")).font(.title3.weight(.semibold))
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 70)
                .foregroundColor(.black)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: player.isPlaying ? 22 : 35, style: .continuous))
                .animation(.easeInOut(duration: 0.2), value: player.isPlaying)
            }
            .layoutPriority(1)
            Button(action: player.skipNext) {
                Image(systemName: "forward.end.fill").font(.title2)
                    .frame(width: 70, height: 70)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(Circle())
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
                qualityText(kbps: s.bitrate / 1000, codec: s.codecs.hasPrefix("mp4a") ? "AAC" : s.codecs.uppercased(), source: m.provider.displayName)
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

    /// Как на Android: «320 kbps · MP3 · VK», битрейт зелёным от 256 kbps.
    private func qualityText(kbps: Int, codec: String, source: String) -> Text {
        let rate = Text("\(kbps) kbps").foregroundColor(kbps >= 256 ? .green : .secondary)
        return rate + Text(" · \(codec) · \(source)").foregroundColor(.secondary)
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
            Button(action: { showMenu = true }) {
                Image(systemName: "ellipsis").rotationEffect(.degrees(90)).font(.system(size: 18)).frame(width: 44, height: 44)
                    .foregroundColor(.primary)
                    .background(Circle().fill(Color.secondary.opacity(0.2)))
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
