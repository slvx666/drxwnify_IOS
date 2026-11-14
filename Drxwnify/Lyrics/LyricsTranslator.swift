import Foundation
import GRDB

/// ИИ-перевод текста песни (Android `LyricsTranslationHelper` + `OpenRouterService`/`MistralService`/`DeepLService`):
/// ключ API вводит пользователь, перевод строк сохраняется в `lyrics.translatedLyrics` вместе с языком и режимом.
enum LyricsTranslator {
    static let providers: [(id: String, url: String)] = [
        ("OpenRouter", "https://openrouter.ai/api/v1/chat/completions"),
        ("OpenAI", "https://api.openai.com/v1/chat/completions"),
        ("Perplexity", "https://api.perplexity.ai/chat/completions"),
        ("Claude", "https://api.anthropic.com/v1/messages"),
        ("Gemini", "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"),
        ("XAi", "https://api.x.ai/v1/chat/completions"),
        ("Mistral", "https://api.mistral.ai/v1/chat/completions"),
        ("DeepL", "https://api.deepl.com/v2/translate"),
        ("Custom", ""),
    ]

    static let models: [String: [String]] = [
        "OpenRouter": ["google/gemini-2.5-flash-lite", "google/gemini-2.5-flash", "x-ai/grok-4.1-fast", "deepseek/deepseek-v3.1-terminus:exacto",
                       "openai/gpt-4o-mini", "meta-llama/llama-4-scout", "openai/gpt-5-nano", "openai/gpt-oss-120b", "google/gemini-3-flash-preview"],
        "OpenAI": ["gpt-4o-mini", "gpt-4o", "gpt-4-turbo"],
        "Claude": ["claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"],
        "Gemini": ["gemini-flash-lite-latest", "gemini-2.5-flash-lite", "gemini-flash-latest", "gemini-2.5-flash", "gemini-3-flash-preview"],
        "Perplexity": ["sonar", "sonar-pro", "sonar-reasoning"],
        "XAi": ["grok-4-1-fast", "grok-vision-beta"],
        "Mistral": ["mistral-large-latest", "mistral-medium-latest", "mistral-small-latest", "mistral-tiny-latest"],
    ]

    static let helpKeys: [String: String] = [
        "OpenRouter": "ai_provider_openrouter_help", "OpenAI": "ai_provider_openai_help", "Perplexity": "ai_provider_perplexity_help",
        "Claude": "ai_provider_claude_help", "Gemini": "ai_provider_gemini_help", "XAi": "ai_provider_xai_help",
        "Mistral": "ai_provider_mistral_help", "DeepL": "ai_provider_deepl_help",
    ]

    static let languages: [(String, String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"),
        ("ru", "Russian"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"), ("ar", "Arabic"), ("hi", "Hindi"),
        ("bn", "Bengali"), ("pa", "Punjabi"), ("tr", "Turkish"), ("vi", "Vietnamese"), ("th", "Thai"), ("id", "Indonesian"),
        ("pl", "Polish"), ("nl", "Dutch"), ("sv", "Swedish"), ("uk", "Ukrainian"),
    ]

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Config {
        var provider: String
        var apiKey: String
        var baseUrl: String
        var model: String
        var mode: String
        var language: String
        var deeplKey: String
        var formality: String
        var systemPrompt: String

        init(_ s: TypedStore) {
            provider = s.get(PK.aiProvider) ?? "OpenRouter"
            apiKey = s.get(PK.openRouterApiKey) ?? ""
            baseUrl = s.get(PK.openRouterBaseUrl) ?? "https://openrouter.ai/api/v1/chat/completions"
            model = s.get(PK.openRouterModel) ?? "google/gemini-2.5-flash-lite"
            mode = s.get(PK.translateMode) ?? "Literal"
            language = s.get(PK.translateLanguage) ?? "en"
            deeplKey = s.get(PK.deeplApiKey) ?? ""
            formality = s.get(PK.deeplFormality) ?? "default"
            systemPrompt = s.get(PK.aiSystemPrompt) ?? ""
        }
    }

    // MARK: - Сохранённый перевод

    static func saved(_ trackId: String, _ c: Config, database: AppDatabase) -> [String]? {
        guard let row = try? database.pool.read({
            try Row.fetchOne($0, sql: "SELECT translatedLyrics, translationLanguage, translationMode FROM lyrics WHERE id = ?", arguments: [trackId])
        }) else { return nil }
        let text: String = row["translatedLyrics"] ?? ""
        guard !text.isEmpty, row["translationLanguage"] == c.language, row["translationMode"] == c.mode else { return nil }
        return text.components(separatedBy: "\n")
    }

    static func save(_ trackId: String, _ lines: [String]?, _ c: Config, database: AppDatabase) {
        try? database.pool.write {
            try $0.execute(sql: "UPDATE lyrics SET translatedLyrics = ?, translationLanguage = ?, translationMode = ? WHERE id = ?",
                           arguments: [lines?.joined(separator: "\n") ?? "", lines == nil ? "" : c.language, lines == nil ? "" : c.mode, trackId])
        }
    }

    // MARK: - Перевод

    /// Переводит непустые строки; ответ — по строке на каждую входную.
    static func translate(_ lines: [String], _ c: Config) async throws -> [String] {
        let key = c.provider == "DeepL" ? c.deeplKey : c.apiKey
        if key.trimmingCharacters(in: .whitespaces).isEmpty { throw Failure(message: L("ai_error_api_key_required")) }
        if lines.isEmpty { throw Failure(message: L("ai_error_lyrics_empty")) }
        if c.language.isEmpty { throw Failure(message: L("ai_error_language_required")) }
        if c.provider == "DeepL" { return try await deepl(lines, c) }
        let language = languages.first { $0.0 == c.language }?.1 ?? (Locale(identifier: "en").localizedString(forLanguageCode: c.language) ?? c.language)
        let text = lines.joined(separator: "\n")
        let n = lines.count
        let system = c.systemPrompt.isEmpty ? """
            You are a precise lyrics translation assistant. Your output must ALWAYS be a valid JSON array of strings.

            CRITICAL RULES:
            1. Output ONLY a JSON array: ["line1", "line2", "line3"]
            2. NO explanations, NO questions, NO additional text
            3. Each input line maps to exactly one output line
            4. Preserve empty lines as empty strings ""
            5. Return EXACTLY \(n) items in the array
            6. If uncertain, provide best approximation but maintain line count
            """ : c.systemPrompt.replacingOccurrences(of: "{lineCount}", with: String(n))
        let user: String
        if c.mode == "Transcribed" {
            user = """
                Transcribe/transliterate the following \(n) lines phonetically into \(language) script.

                CRITICAL REQUIREMENTS:
                - Convert the SOUND/PRONUNCIATION of the original text into \(language) script
                - DO NOT translate the meaning - only represent how the original words SOUND
                - Use the native script of \(language)
                - Keep punctuation and formatting
                - Preserve line-by-line structure exactly
                - If text is already in \(language) script, return it UNCHANGED

                Input (\(n) lines):
                \(text)

                Output MUST be a JSON array with EXACTLY \(n) strings in \(language) script.
                """
        } else {
            user = """
                Translate the following \(n) lines to \(language).

                IMPORTANT:
                - Provide natural, accurate translation
                - Maintain poetic flow and meaning
                - Keep punctuation appropriate for target language
                - Preserve line-by-line structure exactly
                - For song lyrics, prioritize singability

                Input (\(n) lines):
                \(text)

                Output MUST be a JSON array with EXACTLY \(n) strings.
                """
        }
        let url = c.provider == "Custom" ? c.baseUrl : (providers.first { $0.id == c.provider }?.url ?? c.baseUrl)
        guard let endpoint = URL(string: url.isEmpty ? providers[0].url : url) else { throw Failure(message: L("ai_error_unknown")) }
        var req = URLRequest(url: endpoint, timeoutInterval: 90)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONObject
        if c.provider == "Claude" {
            req.setValue(key.trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": c.model, "system": system, "max_tokens": max(1024, n * 100), "temperature": 0.3,
                    "messages": [["role": "user", "content": user]]]
        } else {
            req.setValue("Bearer " + key.trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "Authorization")
            req.setValue("Drxwnify", forHTTPHeaderField: "X-Title")
            var b: JSONObject = ["messages": [["role": "system", "content": system], ["role": "user", "content": user]],
                                 "temperature": 0.3, "max_tokens": n * 100]
            if !c.model.isEmpty { b["model"] = c.model }
            body = b
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        var attempt = 0
        while true {
            attempt += 1
            let r = try await HTTP.send(req)
            if r.status >= 500 && attempt < 3 {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                continue
            }
            let o = JSON.object(r.data)
            guard r.isSuccess else {
                let msg = o?.obj("error")?.str("message") ?? "HTTP \(r.status)"
                throw Failure(message: L("ai_error_translation_failed") + ": " + msg)
            }
            let content: String?
            if c.provider == "Claude" {
                content = o?.objects("content").compactMap { $0.str("text") }.joined()
            } else {
                content = o?.objects("choices").first?.obj("message")?.str("content")
            }
            guard let raw = content?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                throw Failure(message: L("ai_error_unexpected"))
            }
            return parse(raw)
        }
    }

    /// JSON-массив из ответа (бывает в ```json…```), иначе — строки без нумерации.
    static func parse(_ raw: String) -> [String] {
        if let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end,
           let data = String(raw[start...end]).data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            return arr.map { ($0 as? String) ?? "\($0)" }
        }
        return raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("```") }
            .map { $0.replacingOccurrences(of: #"^\d+\.\s*"#, with: "", options: .regularExpression) }
    }

    private static func deepl(_ lines: [String], _ c: Config) async throws -> [String] {
        let key = c.deeplKey.trimmingCharacters(in: .whitespaces)
        let host = key.hasSuffix(":fx") ? "https://api-free.deepl.com/v2/translate" : "https://api.deepl.com/v2/translate"
        var req = URLRequest(url: URL(string: host)!, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("DeepL-Auth-Key " + key, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let target: String
        switch c.language {
        case "en": target = "EN-US"
        case "pt": target = "PT-BR"
        case "zh": target = "ZH"
        default: target = c.language.uppercased()
        }
        var body: JSONObject = ["text": lines, "target_lang": target, "preserve_formatting": true]
        if c.formality != "default" { body["formality"] = c.formality }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let r = try await HTTP.send(req)
        let o = JSON.object(r.data)
        guard r.isSuccess else { throw Failure(message: L("ai_error_translation_failed") + ": " + (o?.str("message") ?? "HTTP \(r.status)")) }
        let out = (o?.objects("translations") ?? []).map { $0.str("text") ?? "" }
        if out.isEmpty { throw Failure(message: L("ai_error_unexpected")) }
        return out
    }
}
