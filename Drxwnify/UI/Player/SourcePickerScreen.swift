import SwiftUI

/// «Выбрать источник звука»: все версии текущего трека во всех включённых источниках.
/// Выбранная вручную версия запоминается для трека без срока (CRITICAL §2.4, п. 2).
struct SourcePickerScreen: View {
    @EnvironmentObject private var player: PlayerController
    @Environment(\.presentationMode) private var presentation

    @State private var versions: [ProviderMatch] = []
    @State private var loading = true
    @State private var manual: ProviderMatch?

    var body: some View {
        NavigationView {
            List {
                Section(footer: Text(L("audio_source_choose_desc"))) {
                    if let m = player.serving {
                        Text(L("audio_source_current", "\(m.provider.displayName) · \(m.artist) — \(m.title)"))
                            .font(.footnote)
                    }
                    Button(action: chooseAuto) {
                        HStack {
                            Text(L("audio_source_auto")).foregroundColor(.primary)
                            Spacer()
                            if manual == nil { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                        }
                    }
                }
                Section {
                    if loading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(L("audio_source_searching")).foregroundColor(.secondary)
                        }
                    } else if versions.isEmpty {
                        Text(L("audio_source_none")).foregroundColor(.secondary)
                    }
                    ForEach(versions, id: \.self) { v in
                        Button(action: { choose(v) }) {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(v.artist) — \(v.title)").foregroundColor(.primary).lineLimit(2)
                                    Text(detail(v)).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                if isSelected(v) { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                            }
                        }
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle(L("audio_source_choose"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading: Button(L("close")) { presentation.wrappedValue.dismiss() })
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear(perform: load)
    }

    private func detail(_ v: ProviderMatch) -> String {
        let percent = Int((min(v.confidence, 1.0) * 100).rounded())
        var line = L("audio_source_candidate_info", v.provider.displayName, percent)
        if let ms = v.durationMs, ms > 0 { line += " · " + formatDuration(ms: ms) }
        return line + " · ~\(v.expectedKbps) kbps"
    }

    private func isSelected(_ v: ProviderMatch) -> Bool {
        guard let m = player.serving else { return false }
        return m.provider == v.provider && m.trackId == v.trackId
    }

    private func load() {
        guard let t = player.current else { return }
        let engine = player.audioEngine
        let q = t.audioQuery
        manual = engine.manualSelection(q)
        Task {
            let found = await engine.allVersions(q)
            await MainActor.run {
                versions = found
                loading = false
            }
        }
    }

    private func choose(_ v: ProviderMatch) {
        guard let t = player.current else { return }
        let engine = player.audioEngine
        let q = t.audioQuery
        Task {
            await engine.selectManually(q, v)
            await MainActor.run {
                player.reloadCurrent()
                presentation.wrappedValue.dismiss()
            }
        }
    }

    private func chooseAuto() {
        guard let t = player.current else { return }
        let engine = player.audioEngine
        let q = t.audioQuery
        Task {
            await engine.clearManualSelection(q)
            await MainActor.run {
                player.reloadCurrent()
                presentation.wrappedValue.dismiss()
            }
        }
    }
}
