import SwiftUI

/// Текст песни в плеере (LYR-001…010): строка под курсором подсвечена и держится по центру, при пословной разметке
/// слова загораются по очереди; тап по строке перематывает. Меню: обновить, копировать, сдвиг синхронизации.
struct LyricsView: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var env: AppEnvironment

    @State private var lyrics: Lyrics?
    @State private var loading = false
    @State private var loadedFor = ""
    /// Сдвиг текста относительно звука, мс (`song.lyricsOffset`).
    @State private var offsetMs = 0
    @State private var copied = false
    /// ИИ-перевод: строка (`LyricLine.id`) → перевод.
    @State private var translated: [Int: String] = [:]
    @State private var translating = false
    @State private var translateError: String?

    /// Точная позиция: опрос плеера 10 раз в секунду, пока текст на экране (позиция плеера идёт шагом 0,5 с).
    @State private var livePosition: Double = 0
    private let clock = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    private var position: Double { livePosition + Double(offsetMs) / 1000 }
    private var settings: TypedStore { env.prefs.settings }
    private var align: HorizontalAlignment {
        switch settings.get(PK.lyricsTextPosition) ?? "CENTER" {
        case "LEFT": return .leading
        case "RIGHT": return .trailing
        default: return .center
        }
    }
    private var textAlign: TextAlignment { align == .leading ? .leading : (align == .trailing ? .trailing : .center) }
    private var frameAlign: Alignment { align == .leading ? .leading : (align == .trailing ? .trailing : .center) }

    private var currentLine: Int? {
        guard let l = lyrics, l.isSynced else { return nil }
        let t = position + 0.3
        return l.lines.last { !$0.background && ($0.time ?? .infinity) <= t }?.id
    }

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let l = lyrics {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: align, spacing: UIMetrics.isShort ? 10 : 14) {
                            ForEach(l.lines) { line in
                                lineView(line, synced: l.isSynced)
                                    .multilineTextAlignment(textAlign)
                                    .frame(maxWidth: .infinity, alignment: frameAlign)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        guard settings.get(PK.lyricsClick) ?? true, let t = line.time else { return }
                                        player.seek(to: max(0, t - Double(offsetMs) / 1000))
                                        livePosition = t - Double(offsetMs) / 1000
                                    }
                                    .id(line.id)
                            }
                            Text(L("lyrics_from_provider", l.provider)).font(.caption).foregroundColor(.secondary).padding(.top, 8)
                        }
                        .padding(.vertical, 24)
                    }
                    .onChange(of: currentLine) { id in
                        guard let id = id, settings.get(PK.lyricsScrollKey) ?? true else { return }
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onAppear {
                        if let id = currentLine { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .overlay(menu, alignment: .topTrailing)
                .overlay(translateStatus, alignment: .bottom)
            } else {
                VStack(spacing: 12) {
                    Text(L("lyrics_not_found")).foregroundColor(.secondary)
                    Button(L("retry")) { load(refresh: true) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            livePosition = player.exactPosition
            load(refresh: false)
        }
        .onReceive(clock) { _ in
            let p = player.exactPosition
            if abs(p - livePosition) > 0.04 { livePosition = p }
        }
        .onChange(of: player.current?.id) { _ in load(refresh: false) }
    }

    @ViewBuilder private func lineView(_ line: LyricLine, synced: Bool) -> some View {
        if let tr = translated[line.id], !tr.isEmpty {
            VStack(alignment: align, spacing: 2) {
                originalLine(line, synced: synced)
                Text(tr).font(.subheadline).foregroundColor(Color.primary.opacity(line.id == currentLine || !synced ? 0.75 : 0.3))
            }
        } else {
            originalLine(line, synced: synced)
        }
    }

    @ViewBuilder private func originalLine(_ line: LyricLine, synced: Bool) -> some View {
        if let roman = Romanizer.romanize(line.text) {
            if Romanizer.asMain {
                VStack(alignment: align, spacing: 2) {
                    Text(roman).font(lineFont(line)).foregroundColor(color(line, synced: synced))
                    Text(line.text).font(.caption).foregroundColor(.secondary)
                }
            } else {
                VStack(alignment: align, spacing: 2) {
                    baseLine(line, synced: synced)
                    Text(roman).font(.subheadline).foregroundColor(Color.primary.opacity(line.id == currentLine ? 0.75 : 0.3))
                }
            }
        } else {
            baseLine(line, synced: synced)
        }
    }

    private func lineFont(_ line: LyricLine) -> Font {
        let size = CGFloat(settings.get(PK.lyricsTextSize) ?? 24) * (UIMetrics.isShort ? 0.72 : 0.84)
        return line.background ? .system(size: size * 0.75, weight: .semibold) : .system(size: size, weight: .bold)
    }

    @ViewBuilder private func baseLine(_ line: LyricLine, synced: Bool) -> some View {
        let size = CGFloat(settings.get(PK.lyricsTextSize) ?? 24) * (UIMetrics.isShort ? 0.72 : 0.84)
        let font: Font = line.background ? .system(size: size * 0.75, weight: .semibold) : .system(size: size, weight: .bold)
        if synced, !line.words.isEmpty, line.id == currentLine || isCurrentBackground(line) {
            karaoke(line).font(font)
        } else {
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(font)
                .foregroundColor(color(line, synced: synced))
        }
    }

    /// Фоновая строка идёт вместе с основной, на которой стоит курсор.
    private func isCurrentBackground(_ line: LyricLine) -> Bool {
        guard line.background, let c = currentLine, let l = lyrics, line.id > c else { return false }
        return !l.lines[(c + 1)..<line.id].contains { !$0.background }
    }

    /// Пройденные слова — ярко, остальные — тускло.
    private func karaoke(_ line: LyricLine) -> Text {
        let t = position
        return line.words.reduce(Text("")) { acc, w in
            acc + Text(w.text).foregroundColor(w.time <= t ? .primary : Color.primary.opacity(0.4))
        }
    }

    private func color(_ line: LyricLine, synced: Bool) -> Color {
        if !synced { return .primary }
        let base: Double = line.background ? 0.25 : 0.35
        return line.id == currentLine ? .primary : Color.primary.opacity(base)
    }

    private var menu: some View {
        Menu {
            Button(action: { load(refresh: true) }) { Label(L("refetch"), systemImage: "arrow.clockwise") }
            Button(action: copyAll) { Label(L("ios_copy"), systemImage: "doc.on.doc") }
            // Android: пункт меню текста включает и выключает ИИ-перевод (ключ — в «Настройки → Контент»).
            if hasAiKey {
                Button(action: toggleTranslation) {
                    Label(L("ai_lyrics_translation"), systemImage: translated.isEmpty ? "character.bubble" : "character.bubble.fill")
                }
            }
            Section {
                Button(action: { shift(-500) }) { Label(L("ios_lyrics_earlier"), systemImage: "backward") }
                Button(action: { shift(500) }) { Label(L("ios_lyrics_later"), systemImage: "forward") }
                if offsetMs != 0 {
                    Button(action: { shift(-offsetMs) }) {
                        Label("\(L("lyrics_offset")): \(offsetMs) ms → 0", systemImage: "arrow.uturn.backward")
                    }
                }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "ellipsis")
                .rotationEffect(.degrees(copied ? 0 : 90))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.secondary.opacity(0.2)))
                .foregroundColor(.primary)
        }
        .padding(.top, 4)
    }

    private var hasAiKey: Bool {
        let c = LyricsTranslator.Config(settings)
        return !(c.provider == "DeepL" ? c.deeplKey : c.apiKey).trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder private var translateStatus: some View {
        if translating || translateError != nil {
            HStack(spacing: 8) {
                if translating { ProgressView() }
                Text(translateError ?? L("ai_translating_lyrics")).font(.footnote).lineLimit(3)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(Color(.secondarySystemBackground)))
            .padding(.bottom, 8)
            .onTapGesture { translateError = nil }
        }
    }

    private func toggleTranslation() {
        guard let t = player.current, let l = lyrics else { return }
        let c = LyricsTranslator.Config(settings)
        if !translated.isEmpty {
            translated = [:]
            LyricsTranslator.save(t.id, nil, c, database: env.database)
            return
        }
        let source = l.lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        translating = true
        translateError = nil
        let db = env.database
        Task {
            do {
                let out = try await LyricsTranslator.translate(source.map { $0.text }, c)
                await MainActor.run {
                    translating = false
                    guard player.current?.id == t.id else { return }
                    apply(out, to: source)
                    LyricsTranslator.save(t.id, out, c, database: db)
                }
            } catch {
                await MainActor.run {
                    translating = false
                    translateError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { translateError = nil }
                }
            }
        }
    }

    private func apply(_ out: [String], to source: [LyricLine]) {
        var map: [Int: String] = [:]
        for (i, line) in source.enumerated() where i < out.count { map[line.id] = out[i] }
        translated = map
    }

    private func shift(_ ms: Int) {
        guard let t = player.current else { return }
        offsetMs += ms
        env.lyrics.setOffset(t, offsetMs)
    }

    private func copyAll() {
        guard let l = lyrics else { return }
        UIPasteboard.general.string = l.lines.map { $0.text }.joined(separator: "\n")
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func load(refresh: Bool) {
        guard let t = player.current else { return }
        if !refresh && loadedFor == t.id { return }
        loadedFor = t.id
        lyrics = nil
        loading = true
        offsetMs = env.lyrics.offset(t.id)
        let store = env.lyrics
        Task {
            let found = await store.lyrics(for: t, refresh: refresh)
            await MainActor.run {
                guard player.current?.id == t.id else { return }
                lyrics = found
                loading = false
                translated = [:]
                if let l = found, let saved = LyricsTranslator.saved(t.id, LyricsTranslator.Config(settings), database: env.database) {
                    apply(saved, to: l.lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
                }
            }
        }
    }
}
