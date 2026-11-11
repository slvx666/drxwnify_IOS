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

    private var position: Double { player.position + Double(offsetMs) / 1000 }

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
                        LazyVStack(alignment: .leading, spacing: UIMetrics.isShort ? 10 : 14) {
                            ForEach(l.lines) { line in
                                lineView(line, synced: l.isSynced)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture { if let t = line.time { player.seek(to: max(0, t - Double(offsetMs) / 1000)) } }
                                    .id(line.id)
                            }
                            Text(L("lyrics_from_provider", l.provider)).font(.caption).foregroundColor(.secondary).padding(.top, 8)
                        }
                        .padding(.vertical, 24)
                    }
                    .onChange(of: currentLine) { id in
                        guard let id = id else { return }
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onAppear {
                        if let id = currentLine { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .overlay(menu, alignment: .topTrailing)
            } else {
                VStack(spacing: 12) {
                    Text(L("lyrics_not_found")).foregroundColor(.secondary)
                    Button(L("retry")) { load(refresh: true) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { load(refresh: false) }
        .onChange(of: player.current?.id) { _ in load(refresh: false) }
    }

    @ViewBuilder private func lineView(_ line: LyricLine, synced: Bool) -> some View {
        let font: Font = line.background ? .body.weight(.semibold) : (UIMetrics.isShort ? .headline : .title3.weight(.bold))
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
            }
        }
    }
}
