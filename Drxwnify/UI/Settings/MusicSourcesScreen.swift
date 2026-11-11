import SwiftUI

/// «Источники аудио»: включение источников, их порядок (перетаскиванием) и режим выбора версии.
/// Ключи настроек — как на Android: `audioSource*`, `audioSourceOrder`, `sourcePickMode`.
struct MusicSourcesScreen: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        MusicSourcesContent(settings: env.prefs.settings)
    }
}

private struct MusicSourcesContent: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject var settings: TypedStore

    /// Soulseek на iOS появится на последнем этапе.
    private var order: [AudioProviderId] {
        AudioProviderId.parseOrder(settings.get(PK.audioSourceOrder)).filter { $0 != .SOULSEEK }
    }

    private func key(_ id: AudioProviderId) -> PrefKey<Bool> {
        switch id {
        case .SOUNDCLOUD: return PK.audioSourceSoundCloud
        case .YOUTUBE: return PK.audioSourceYouTube
        case .VK: return PK.audioSourceVk
        case .BANDCAMP: return PK.audioSourceBandcamp
        case .AUDIUS: return PK.audioSourceAudius
        case .LOSSLESS: return PK.audioSourceLossless
        case .SOULSEEK: return PK.audioSourceSoulseek
        }
    }

    private func title(_ id: AudioProviderId) -> String {
        switch id {
        case .SOUNDCLOUD: return L("audio_source_soundcloud")
        case .YOUTUBE: return L("audio_source_youtube")
        case .VK: return L("audio_source_vk")
        case .BANDCAMP: return L("audio_source_bandcamp")
        case .AUDIUS: return L("audio_source_audius")
        case .LOSSLESS: return L("audio_source_lossless")
        case .SOULSEEK: return L("audio_source_soulseek")
        }
    }

    private func description(_ id: AudioProviderId) -> String {
        switch id {
        case .SOUNDCLOUD: return L("audio_source_soundcloud_description")
        case .YOUTUBE: return L("audio_source_youtube_description")
        case .VK:
            if !(settings.get(PK.vkAccessToken) ?? "").isEmpty { return L("audio_source_vk_description") }
            return env.vk.sharedInUse ? L("vk_shared_demo_short", RemoteConfig.shared.config.vkShared?.dailyTracks ?? 0) : L("vk_login_required")
        case .BANDCAMP: return L("audio_source_bandcamp_description")
        case .AUDIUS: return L("audio_source_audius_description")
        case .LOSSLESS: return L("audio_source_lossless_description")
        case .SOULSEEK: return L("audio_source_soulseek_description")
        }
    }

    private var allDisabled: Bool { !order.contains { settings.get(key($0)) ?? true } }

    private var mode: Binding<String> {
        Binding(get: { settings.get(PK.sourcePickMode) ?? "AUTO" }, set: { settings.set(PK.sourcePickMode, $0) })
    }

    var body: some View {
        List {
            Section(header: Text(L("audio_sources_title")), footer: Text(L(allDisabled ? "audio_sources_all_disabled" : "audio_sources_info"))) {
                ForEach(order, id: \.self) { id in
                    Toggle(isOn: Binding(get: { settings.get(key(id)) ?? true }, set: { settings.set(key(id), $0) })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title(id))
                            Text(description(id)).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .onMove { source, destination in
                    var list = order
                    list.move(fromOffsets: source, toOffset: destination)
                    settings.set(PK.audioSourceOrder, (list + [.SOULSEEK]).map { $0.rawValue }.joined(separator: ","))
                }
            }
            Section(header: Text(L("source_pick_mode"))) {
                ForEach(["AUTO", "SPEED", "QUALITY"], id: \.self) { m in
                    Button(action: { mode.wrappedValue = m }) {
                        HStack {
                            Text(L(m == "AUTO" ? "source_pick_auto" : (m == "SPEED" ? "source_pick_speed" : "source_pick_quality")))
                                .font(.footnote)
                                .foregroundColor(.primary)
                            Spacer()
                            if mode.wrappedValue == m { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                        }
                    }
                }
            }
            if (settings.get(PK.vkAccessToken) ?? "").isEmpty {
                Section {
                    NavigationLink(destination: VkLoginScreen()) {
                        Label(L("vk_login"), systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .environment(\.editMode, .constant(.active))
        .navigationTitle(L("music_sources"))
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerInset()
    }
}
