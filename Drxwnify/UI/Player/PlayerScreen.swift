import SwiftUI
import Nuke

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
    /// Прослушивания Spotify у играющего трека (из ответа альбома, как на Android 2.1.5).
    @State private var plays: Int?
    @State private var showCover = false
    @State private var showShare = false
    @State private var seekHint: Int?

    var body: some View {
        // Пункт 0б: обложка (или текст) занимает только оставшееся место, поэтому нижний ряд виден на любом экране,
        // включая 320×568 («Увеличенный» масштаб). Кнопки на коротком экране меньше.
        // Как на Android: обложка сверху, название сразу под ней, управление внизу, между ними — воздух.
        VStack(spacing: 0) {
            header
            GeometryReader { box in
                VStack(spacing: 0) {
                    middle(in: CGSize(width: box.size.width, height: coverBox(box.size)))
                        .frame(height: coverBox(box.size))
                    titleRow.padding(.top, compact ? 12 : 18)
                    Spacer(minLength: 6)
                }
            }
            slider.padding(.top, compact ? 2 : 8)
            controls.padding(.top, compact ? 6 : 12)
            bottomBar.padding(.top, compact ? 6 : 12)
        }
        .padding(.horizontal, compact ? 16 : 24)
        .padding(.bottom, compact ? 4 : 8)
        .cappedDynamicType()
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
        .background(EmptyView().sheet(isPresented: $showShare) {
            if let t = player.current {
                SendTracksSheet(tracks: [t], addToPlaylist: { open(nil) { env.addToPlaylist = TrackBatch(tracks: [t]) } })
                    .environmentObject(env).environmentObject(downloads)
                    .modifier(MediumSheet())
                    .modifier(ThemedRoot(theme: AppTheme.current))
            }
        })
        .overlay(showSleep ? SleepTimerDialog(isPresented: $showSleep).environmentObject(player) : nil)
        .onChange(of: player.current == nil) { empty in
            if empty { presentation.wrappedValue.dismiss() }
        }
        .onAppear {
            loadPlays()
            if let t = player.current { likes.refresh([t]) }
            UIApplication.shared.isIdleTimerDisabled = env.prefs.settings.get(PK.keepScreenOn) ?? false
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: player.current?.id) { _ in
            loadPlays()
            if let t = player.current { likes.refresh([t]) }
        }
    }

    /// Короткий экран (высота меньше 700 pt: iPhone 8, SE, «Увеличенный» масштаб).
    private var compact: Bool { UIMetrics.height < 700 }
    private var tiny: Bool { UIMetrics.isShort }
    private var controlHeight: CGFloat { tiny ? 52 : (compact ? 60 : 70) }
    private var squareSide: CGFloat { tiny ? 34 : (compact ? 38 : 42) }

    /// Высота места под обложку: квадрат по ширине, но так, чтобы под ним поместилось название.
    private func coverBox(_ size: CGSize) -> CGFloat {
        let titleSpace: CGFloat = compact ? 74 : 92
        return max(80, min(size.width, size.height - titleSpace))
    }

    /// Обложка или текст песни в оставшемся месте.
    @ViewBuilder private func middle(in size: CGSize) -> some View {
        let gap: CGFloat = compact ? 20 : 24
        // На маленьком экране обложка чуть меньше ширины, чтобы кнопкам и названию было где дышать.
        let widthShare: CGFloat = compact ? 0.86 : 1
        let side: CGFloat = max(60, min(size.width * widthShare, size.height - gap))
        if showLyrics {
            LyricsView().frame(width: size.width, height: size.height)
        } else {
            artwork(side: side).frame(width: size.width, height: size.height, alignment: .center)
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
                Text(L("now_playing")).font(.headline)
                if let album = player.current?.albumName, !album.isEmpty {
                    Text(album).font(.subheadline).lineLimit(1)
                        .onTapGesture { openAlbum() }
                }
                qualityLine
                if let plays = plays {
                    Text(L("ios_spotify_plays", NumberFormatter.localizedString(from: NSNumber(value: plays), number: .decimal)))
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button(action: { env.homeRequest += 1 }) {
                Image(systemName: "house").font(.title3).frame(width: 44, height: 44)
            }
        }
        .foregroundColor(.primary)
        .padding(.horizontal, -12)
        .padding(.top, compact ? 0 : 6)
    }

    // MARK: - Обложка

    private func artwork(side: CGFloat) -> some View {
        ArtworkView(url: SpotifyImageCDN.large(player.current?.artworkUrl), size: side, cornerRadius: compact ? 12 : 16)
            .shadow(color: Color.black.opacity(0.35), radius: 16, y: 8)
            .id(player.current?.artworkUrl ?? "")
            .overlay(seekOverlay(side))
            .gesture(DragGesture(minimumDistance: 30).onEnded { g in
                guard abs(g.translation.width) > abs(g.translation.height) else { return }
                if g.translation.width < -50 { player.skipNext() }
                if g.translation.width > 50 { player.skipPrevious() }
            })
            // Как на Android: тап по левому/правому краю — перемотка на 5 с; тап по середине — обложка крупно.
            .overlay(HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).frame(width: side * 0.3)
                    .onTapGesture { seek(-5) }
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { showCover = true }
                Color.clear.contentShape(Rectangle()).frame(width: side * 0.3)
                    .onTapGesture { seek(5) }
            })
            .sheet(isPresented: $showCover) {
                CoverViewer(url: SpotifyImageCDN.large(player.current?.artworkUrl), title: player.current?.title ?? "cover")
                    .modifier(ThemedRoot(theme: AppTheme.current))
            }
    }

    @ViewBuilder private func seekOverlay(_ side: CGFloat) -> some View {
        if let s = seekHint {
            Label(s > 0 ? "+\(s) s" : "\(s) s", systemImage: s > 0 ? "goforward" : "gobackward")
                .font(.headline).foregroundColor(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: s > 0 ? .trailing : .leading)
                .padding(16)
                .transition(.opacity)
        }
    }

    private func seek(_ delta: Int) {
        player.seek(to: max(0, min(player.duration, player.position + Double(delta))))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation { seekHint = (seekHint ?? 0) * (seekHint.map { ($0 > 0) == (delta > 0) } == true ? 1 : 0) + delta }
        let mark = seekHint
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { if seekHint == mark { withAnimation { seekHint = nil } } }
    }

    private func openAlbum() {
        guard let t = player.current, let id = t.albumId, !id.isEmpty, t.catalogId != nil else { return }
        open(AppLinks.Target(kind: .album, id: id, title: t.albumName, by: nil))
    }

    private func openArtist() {
        guard let a = player.current?.artists.first, let id = a.id, !id.isEmpty else { return }
        open(AppLinks.Target(kind: .artist, id: id, title: a.name, by: nil))
    }

    private func loadPlays() {
        plays = nil
        guard let t = player.current, let cid = t.catalogId, let albumId = t.albumId, !albumId.isEmpty else { return }
        let api = env.spotify
        Task {
            let album = try? await api.album(albumId)
            let n = album?.tracks.first { $0.id == cid }?.playCount
            await MainActor.run { if player.current?.id == t.id { plays = n } }
        }
    }

    // MARK: - Название и кнопки справа

    private var titleRow: some View {
        HStack(spacing: tiny ? 6 : 8) {
            VStack(alignment: .leading, spacing: tiny ? 2 : 4) {
                // Тап по названию — альбом, по исполнителю — его страница (как на Android); долгое нажатие — копировать.
                Text(player.current?.title ?? "")
                    .font((tiny ? Font.headline : Font.title3).weight(.bold))
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .onTapGesture { openAlbum() }
                    .onLongPressGesture { copy(player.current?.title) }
                Text(player.current?.artistNames ?? "")
                    .font(tiny ? .subheadline : .body)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .onTapGesture { openArtist() }
                    .onLongPressGesture { copy(player.current?.artistNames) }
            }
            Spacer(minLength: 0)
            roundButton("arrowshape.turn.up.right", action: share)
            downloadButton
            Button(action: toggleLike) {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: squareSide, height: squareSide)
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
                        .frame(width: squareSide, height: squareSide).background(Color.secondary.opacity(0.2))
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
            .frame(width: squareSide, height: squareSide)
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

    /// «Поделиться» как на Android — нижнее окно: ссылкой, файлом (если скачан), в чат, в плейлист.
    private func share() { showShare = true }

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
        HStack(spacing: compact ? 10 : 12) {
            Button(action: player.skipPrevious) {
                Image(systemName: "backward.end.fill").font(.title2)
                    .frame(width: controlHeight, height: controlHeight)
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
                            Text(L(player.isPlaying ? "pause" : "play")).font((tiny ? Font.headline : Font.title3).weight(.semibold)).lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: controlHeight)
                .foregroundColor(.black)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: player.isPlaying ? controlHeight * 0.32 : controlHeight / 2, style: .continuous))
                .animation(.easeInOut(duration: 0.2), value: player.isPlaying)
            }
            .layoutPriority(1)
            Button(action: player.skipNext) {
                Image(systemName: "forward.end.fill").font(.title2)
                    .frame(width: controlHeight, height: controlHeight)
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
                Text([L("ios_downloaded"), s.codecs.hasPrefix("mp4a") ? "AAC" : s.codecs.uppercased(), s.bitrate > 0 ? "\(s.bitrate / 1000) kbps" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
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
        // Битрейт ещё меряется (источник его не сообщил) — пока без числа, а не «0 kbps».
        guard kbps > 0 else { return Text("\(codec) · \(source)").foregroundColor(.secondary) }
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


/// Обложка во весь экран: щипок — приближение, тап — закрыть, удержание — «Сохранить» / «Поделиться» (как на Android).
struct CoverViewer: View {
    let url: String?
    var title = "cover"
    @Environment(\.presentationMode) private var presentation
    @State private var scale: CGFloat = 1
    @State private var actions = false
    @State private var shareItems: [Any]?
    @State private var saved = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ArtworkView(url: url, size: UIMetrics.width, cornerRadius: 0)
                .scaleEffect(scale)
                .gesture(MagnificationGesture().onChanged { scale = max(1, min(4, $0)) }.onEnded { _ in withAnimation { scale = 1 } })
            if saved {
                Text(L("ios_cover_saved")).font(.subheadline.weight(.semibold)).foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8).background(Capsule().fill(Color.black.opacity(0.7)))
                    .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 40)
            }
        }
        .onTapGesture { presentation.wrappedValue.dismiss() }
        .onLongPressGesture {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            actions = true
        }
        .actionSheet(isPresented: $actions) {
            ActionSheet(title: Text(title), buttons: [
                .default(Text(L("ios_cover_save"))) { withImage { img in
                    UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                    withAnimation { saved = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { saved = false } }
                } },
                .default(Text(L("share"))) { withImage { shareItems = [$0] } },
                .cancel(),
            ])
        }
        .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) {
            ShareSheet(items: shareItems ?? [])
        }
    }

    /// Картинка в полном размере (без уменьшения под экран).
    private func withImage(_ use: @escaping (UIImage) -> Void) {
        guard let u = SpotifyImageCDN.candidates(url).first else { return }
        ImagePipeline.shared.loadImage(with: u) { result in
            if case .success(let r) = result { use(r.image) }
        }
    }
}
