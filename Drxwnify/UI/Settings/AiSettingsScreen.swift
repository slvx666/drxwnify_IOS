import SwiftUI

/// «ИИ-перевод текста» (Android `AiSettings`): провайдер, ключ, модель, режим, язык, системный промпт.
struct AiSettingsScreen: View {
    @ObservedObject var settings: TypedStore

    private func binding(_ key: PrefKey<String>, _ def: String) -> Binding<String> {
        Binding(get: { settings.get(key) ?? def }, set: { settings.set(key, $0) })
    }

    private var provider: String { settings.get(PK.aiProvider) ?? "OpenRouter" }

    var body: some View {
        List { ThemedRows {
            Section(header: Text(L("ai_provider")), footer: helpFooter) {
                Picker(L("ai_provider"), selection: Binding(get: { provider }, set: { p in
                    settings.set(PK.aiProvider, p)
                    // Как на Android: у провайдера свой адрес и первая модель из списка.
                    if let url = LyricsTranslator.providers.first(where: { $0.id == p })?.url, p != "Custom" { settings.set(PK.openRouterBaseUrl, url) }
                    if let m = LyricsTranslator.models[p]?.first { settings.set(PK.openRouterModel, m) }
                })) {
                    ForEach(LyricsTranslator.providers, id: \.id) { Text($0.id).tag($0.id) }
                }
                if provider == "Custom" {
                    TextField(L("ai_base_url"), text: binding(PK.openRouterBaseUrl, ""))
                        .keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true)
                }
            }
            Section(header: Text(L("ai_setup_guide"))) {
                if provider == "DeepL" {
                    SecureField("DeepL " + L("ai_api_key"), text: binding(PK.deeplApiKey, ""))
                    Picker(L("ai_deepl_formality"), selection: binding(PK.deeplFormality, "default")) {
                        Text(L("ai_deepl_formality_default")).tag("default")
                        Text(L("ai_deepl_formality_more")).tag("more")
                        Text(L("ai_deepl_formality_less")).tag("less")
                    }
                } else {
                    SecureField(L("ai_api_key"), text: binding(PK.openRouterApiKey, ""))
                    if let models = LyricsTranslator.models[provider], !models.isEmpty {
                        Picker(L("ai_model"), selection: binding(PK.openRouterModel, models[0])) {
                            ForEach(Array(Set(models + [settings.get(PK.openRouterModel) ?? models[0]])).sorted(), id: \.self) { Text($0).tag($0) }
                        }
                    }
                    TextField(L("ai_model"), text: binding(PK.openRouterModel, ""))
                        .autocapitalization(.none).disableAutocorrection(true)
                }
            }
            Section(header: Text(L("ai_translation_mode"))) {
                if provider != "DeepL" {
                    Picker(L("ai_translation_mode"), selection: binding(PK.translateMode, "Literal")) {
                        Text(L("ai_translation_literal")).tag("Literal")
                        Text(L("ai_translation_transcribed")).tag("Transcribed")
                    }
                }
                Picker(L("ai_target_language"), selection: binding(PK.translateLanguage, "en")) {
                    ForEach(LyricsTranslator.languages, id: \.0) { code, _ in
                        Text(Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code).tag(code)
                    }
                }
            }
            if provider != "DeepL" {
                Section(header: Text(L("ai_system_prompt")), footer: Text(L("ai_system_prompt_desc") + "\n" + L("ai_system_prompt_placeholder"))) {
                    TextEditor(text: binding(PK.aiSystemPrompt, "")).frame(minHeight: 90)
                    if !(settings.get(PK.aiSystemPrompt) ?? "").isEmpty {
                        Button(L("ai_system_prompt_reset")) { settings.set(PK.aiSystemPrompt, "") }
                    }
                }
            }
            Color.clear.frame(height: 1).listRowBackground(Color.clear).miniPlayerInset()
        }}
        .themedList()
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("ai_lyrics_translation"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var helpFooter: some View {
        if let key = LyricsTranslator.helpKeys[provider] { Text(L(key)) }
    }
}
