import SwiftUI

/// Итоги полноэкранной историей, как Spotify Wrapped (Android 2.3.0 `MonthReviewStory`). Один движок для трёх видов:
/// итоги месяца приложения, итоги Spotify за выбранный период и итоги Яндекса по лайкам.
struct Story {
    struct Item: Hashable {
        var title: String
        var subtitle: String?
        var image: String?
        /// «N раз» / «в лайках: N»; nil — без числа (Spotify).
        var note: String?
        var round = false
    }

    enum Page {
        case hello(title: String, sub: String)
        case big(pre: String, value: String, unit: String, extra: String?)
        case one(pre1: String, pre2: String, item: Item, track: Track?)
        case tracks(title: String, items: [Item], track: Track?)
        case artists(title: String, items: [Item], track: Track?)
        case genres(title: String, lines: [String])
        case bars(title: String, values: [(String, Int)], extra: String?)
        case card(title: String, lines: [String], items: [Item])

        var duration: TimeInterval? {
            switch self {
            case .hello: return 4.7
            case .big, .bars: return 8
            case .one: return 11
            case .tracks, .artists: return 12
            case .genres: return 11
            case .card: return nil
            }
        }

        var track: Track? {
            switch self {
            case .one(_, _, _, let t), .tracks(_, _, let t), .artists(_, _, let t): return t
            default: return nil
            }
        }
    }

    var pages: [Page]
    /// Подпись карточки «Поделиться».
    var title: String
}

/// Появление: элемент сразу занимает своё место, проявляется и доезжает последний кусок пути (кривая «Settle»).
private struct Appear: ViewModifier {
    let delay: Double
    var fromRight = false
    var duration: Double = 0.9
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.97)
            .offset(x: shown || !fromRight ? 0 : UIMetrics.width * 0.35, y: shown || fromRight ? 0 : 36)
            .onAppear {
                withAnimation(Animation.timingCurve(0.22, 1, 0.36, 1, duration: duration).delay(delay)) { shown = true }
            }
    }
}

private extension View {
    func appear(_ delay: Double, fromRight: Bool = false, duration: Double = 0.9) -> some View {
        modifier(Appear(delay: delay, fromRight: fromRight, duration: duration))
    }
}

struct StoryView: View {
    let story: Story
    var onClose: () -> Void
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var audio: StoryAudio
    @State private var index = 0
    @State private var elapsed: TimeInterval = 0
    @State private var holding = false
    @State private var userPaused = false
    @State private var direction: CGFloat = 1
    @State private var shareItems: [Any]?
    @State private var resumeMain = false
    private let tick = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    init(story: Story, engine: AudioFallbackEngine, onClose: @escaping () -> Void) {
        self.story = story
        self.onClose = onClose
        _audio = StateObject(wrappedValue: StoryAudio(engine: engine))
    }

    private var page: Story.Page { story.pages[min(index, story.pages.count - 1)] }
    private var paused: Bool { holding || userPaused }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.12, green: 0.05, blue: 0.22), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            content
                .id(index)
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.04)).combined(with: .offset(x: 30 * direction)),
                                        removal: .opacity.combined(with: .offset(x: -30 * direction))))
            topBar
        }
        .foregroundColor(.white)
        .contentShape(Rectangle())
        // Листается только свайпами; удержание — пауза (Android 2.3.0).
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            if v.translation.width < -40 { go(index + 1) } else if v.translation.width > 40 { go(index - 1) }
        })
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.25).onChanged { _ in holding = true }.sequenced(before: DragGesture(minimumDistance: 0)).onEnded { _ in holding = false })
        .onReceive(tick) { _ in
            guard !paused, let d = page.duration else { return }
            elapsed += 0.05
            if elapsed >= d { go(index + 1) }
        }
        .onAppear {
            resumeMain = env.player.isPlaying
            if resumeMain { env.player.pause() }
            audio.play(page.track)
        }
        .onDisappear {
            audio.stop()
            if resumeMain { env.player.resume() }
        }
        .onChange(of: paused) { audio.paused = $0 }
        .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) { ShareSheet(items: shareItems ?? []) }
        .statusBar(hidden: true)
    }

    private func go(_ i: Int) {
        guard i >= 0, i < story.pages.count else { return }
        direction = i > index ? 1 : -1
        withAnimation(.easeInOut(duration: 0.6)) {
            index = i
            elapsed = 0
        }
        // После жанров трек не обрывается: последняя страница продолжает тот же.
        if let t = story.pages[i].track { audio.play(t) }
    }

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0..<story.pages.count, id: \.self) { i in
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.3))
                            Capsule().fill(Color.white).frame(width: g.size.width * fill(i))
                        }
                    }
                    .frame(height: 3)
                }
            }
            HStack(spacing: 14) {
                Image(systemName: "speaker.fill").font(.caption)
                Slider(value: Binding(get: { Double(audio.volume) }, set: { audio.volume = Float($0) }), in: 0...1)
                    .accentColor(.white).frame(maxWidth: 140)
                Spacer()
                Button(action: { userPaused.toggle() }) { Image(systemName: userPaused ? "play.fill" : "pause.fill") }
                Button(action: onClose) { Image(systemName: "xmark").font(.body.weight(.semibold)) }
                    .accessibility(label: Text(L("story_close")))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private func fill(_ i: Int) -> CGFloat {
        if i < index { return 1 }
        if i > index { return 0 }
        guard let d = story.pages[i].duration else { return 1 }
        return CGFloat(min(1, elapsed / d))
    }

    @ViewBuilder private var content: some View {
        switch page {
        case let .hello(title, sub):
            VStack(spacing: 18) {
                Spacer()
                Text(title).font(.system(size: 44, weight: .heavy)).appear(0.1, duration: 1.2)
                Text(sub).font(.title3.weight(.semibold)).multilineTextAlignment(.center).appear(0.9, duration: 1.2)
                Spacer()
            }
            .padding(28)
        case let .big(pre, value, unit, extra):
            VStack(spacing: 14) {
                Spacer()
                Text(pre).font(.title3.weight(.semibold)).multilineTextAlignment(.center).appear(0.1)
                Text(value).font(.system(size: 72, weight: .black)).minimumScaleFactor(0.5).lineLimit(1).appear(1.2)
                Text(unit).font(.title3).appear(1.6)
                if let e = extra { Text(e).font(.headline).foregroundColor(.white.opacity(0.8)).multilineTextAlignment(.center).appear(2.6) }
                Spacer()
            }
            .padding(28)
        case let .one(pre1, pre2, item, _):
            VStack(spacing: 18) {
                Spacer()
                Text(pre1).font(.title3.weight(.semibold)).multilineTextAlignment(.center).appear(0.1)
                Text(pre2).font(.headline).foregroundColor(.white.opacity(0.75)).multilineTextAlignment(.center).appear(1.2)
                VStack(spacing: 10) {
                    ArtworkView(url: item.image, size: min(240, UIMetrics.width * 0.6), cornerRadius: item.round ? 0 : 12, circle: item.round,
                                placeholderSymbol: item.round ? "person.fill" : "music.note")
                    Text(item.title).font(.title.weight(.heavy)).multilineTextAlignment(.center).lineLimit(2)
                    if let s = item.subtitle { Text(s).font(.headline).foregroundColor(.white.opacity(0.8)) }
                    if let n = item.note { Text(n).font(.subheadline.weight(.semibold)).foregroundColor(.white.opacity(0.85)) }
                }
                .appear(2.8, fromRight: true)
                Spacer()
            }
            .padding(24)
        case let .tracks(title, items, _):
            listPage(title, items, bigCount: 5, cover: 54, small: 36)
        case let .artists(title, items, _):
            listPage(title, items, bigCount: 5, cover: 74, small: 48)
        case let .genres(title, lines):
            VStack(alignment: .leading, spacing: 14) {
                Spacer()
                Text(title).font(.title.weight(.heavy)).appear(0.1)
                ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                    Text(l).font(.title3.weight(.semibold)).appear(0.8 + Double(i) * 0.5, fromRight: true)
                }
                Spacer()
            }
            .padding(28)
        case let .bars(title, values, extra):
            VStack(alignment: .leading, spacing: 16) {
                Spacer()
                Text(title).font(.title2.weight(.heavy)).appear(0.1)
                let top = max(1, values.map { $0.1 }.max() ?? 1)
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                        VStack(spacing: 4) {
                            Text("\(v.1)").font(.system(size: 9, weight: .semibold))
                            RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.85))
                                .frame(height: max(3, CGFloat(v.1) / CGFloat(top) * 180))
                            Text(v.0).font(.system(size: 9))
                        }
                        .frame(maxWidth: .infinity)
                        .appear(0.6 + Double(i) * 0.08)
                    }
                }
                if let e = extra { Text(e).font(.headline).appear(1.8) }
                Spacer()
            }
            .padding(24)
        case let .card(title, lines, items):
            cardPage(title, lines, items)
        }
    }

    /// Списки: выровнены по верху (отступ 68), место распределяется между строками; топ-5 крупно, остальное двумя колонками.
    /// Порядок появления: мелкие места снизу вверх с 600 мс по 70 мс, затем +350 мс, затем топ-5 с 5-го по 1-е.
    private func listPage(_ title: String, _ items: [Story.Item], bigCount: Int, cover: CGFloat, small: CGFloat) -> some View {
        let big = Array(items.prefix(bigCount))
        let rest = Array(items.dropFirst(bigCount))
        let half = (rest.count + 1) / 2
        let restStart = 0.6
        let restEnd = restStart + Double(rest.count) * 0.07 + 0.35
        let gaps = [0.5, 0.6, 0.7, 0.8, 0.9]
        func bigDelay(_ i: Int) -> Double {
            // 5-е первым, 1-е последним.
            var t = restEnd
            for k in stride(from: big.count - 1, to: i, by: -1) { t += gaps[min(k, gaps.count - 1)] }
            return t
        }
        return VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.title2.weight(.heavy)).padding(.bottom, 10).appear(0.05)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(big.enumerated()), id: \.offset) { i, it in
                    HStack(spacing: 12) {
                        Text("\(i + 1)").font(.system(size: 24, weight: .black)).frame(width: 30)
                        ArtworkView(url: it.image, size: it.round ? max(54, cover - CGFloat(i) * 6) : cover, cornerRadius: 6, circle: it.round,
                                    placeholderSymbol: it.round ? "person.fill" : "music.note")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(it.title).font(it.round ? .system(size: max(18, 25 - CGFloat(i) * 2), weight: .bold) : .headline).lineLimit(1)
                            let sub = [it.subtitle, it.note].compactMap { $0 }.joined(separator: " · ")
                            if !sub.isEmpty { Text(sub).font(.caption).foregroundColor(.white.opacity(0.75)).lineLimit(1) }
                        }
                    }
                    .appear(bigDelay(i), fromRight: true)
                    Spacer(minLength: 4)
                }
                HStack(alignment: .top, spacing: 12) {
                    ForEach(0..<2, id: \.self) { col in
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(rest.enumerated()).filter { col == 0 ? $0.offset < half : $0.offset >= half }, id: \.offset) { k, it in
                                HStack(spacing: 6) {
                                    Text("\(bigCount + k + 1)").font(.caption.weight(.bold)).frame(width: 20)
                                    ArtworkView(url: it.image, size: small, cornerRadius: 4, circle: it.round,
                                                placeholderSymbol: it.round ? "person.fill" : "music.note")
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(it.title).font(.caption.weight(.semibold)).lineLimit(1)
                                        if let n = it.note ?? it.subtitle { Text(n).font(.system(size: 10)).foregroundColor(.white.opacity(0.7)).lineLimit(1) }
                                    }
                                }
                                .appear(restStart + Double(rest.count - 1 - k) * 0.07)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 18)
        .padding(.top, 68)
    }

    private func cardView(_ title: String, _ lines: [String], _ items: [Story.Item]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.weight(.heavy))
            ForEach(lines, id: \.self) { Text($0).font(.headline) }
            ForEach(Array(items.prefix(5).enumerated()), id: \.offset) { i, it in
                HStack(spacing: 10) {
                    Text("\(i + 1)").font(.headline.weight(.black)).frame(width: 22)
                    Text(it.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
            }
            Text("Drxwnify").font(.caption.weight(.bold)).opacity(0.7)
        }
        .padding(22)
        .frame(width: min(340, UIMetrics.width - 40), alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22).fill(LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)))
        .foregroundColor(.white)
    }

    private func cardPage(_ title: String, _ lines: [String], _ items: [Story.Item]) -> some View {
        VStack(spacing: 18) {
            Spacer()
            cardView(title, lines, items).appear(0.2)
            HStack(spacing: 12) {
                Button(L("story_share")) { if let img = snapshot(title, lines, items) { shareItems = [img] } }
                Button(L("story_save")) { if let img = snapshot(title, lines, items) { UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil) } }
                Button(L("story_restart")) { go(0) }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(StoryButton())
            Spacer()
        }
        .padding(20)
    }

    /// PNG карточки.
    private func snapshot(_ title: String, _ lines: [String], _ items: [Story.Item]) -> UIImage? {
        let host = UIHostingController(rootView: cardView(title, lines, items).padding(10).background(Color.black))
        let size = host.sizeThatFits(in: CGSize(width: 400, height: 1200))
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.backgroundColor = .black
        let r = UIGraphicsImageRenderer(size: size)
        return r.image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
    }
}

private struct StoryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.3 : 0.18)))
            .foregroundColor(.white)
    }
}
