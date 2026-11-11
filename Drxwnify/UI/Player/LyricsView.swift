import SwiftUI

/// Текст песни в плеере (LYR): строка под курсором подсвечена и держится по центру, тап по строке перематывает.
struct LyricsView: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var env: AppEnvironment

    @State private var lyrics: Lyrics?
    @State private var loading = false
    @State private var loadedFor = ""

    private var currentLine: Int? {
        guard let l = lyrics, l.isSynced else { return nil }
        let t = player.position + 0.3
        return l.lines.last { ($0.time ?? .infinity) <= t }?.id
    }

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let l = lyrics {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(l.lines) { line in
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .font(.title3.weight(.bold))
                                    .foregroundColor(color(line, synced: l.isSynced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture { if let t = line.time { player.seek(to: t) } }
                                    .id(line.id)
                            }
                            Text(l.provider).font(.caption).foregroundColor(.secondary).padding(.top, 8)
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

    private func color(_ line: LyricLine, synced: Bool) -> Color {
        if !synced { return .primary }
        return line.id == currentLine ? .primary : Color.primary.opacity(0.35)
    }

    private func load(refresh: Bool) {
        guard let t = player.current else { return }
        if !refresh && loadedFor == t.id { return }
        loadedFor = t.id
        lyrics = nil
        loading = true
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
