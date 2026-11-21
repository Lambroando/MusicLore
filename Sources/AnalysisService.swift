import Foundation

struct TrackAnalysis: Codable, Equatable {
    let storyAndReason: String
    let context: String
    let lyricsExplanation: String
    let lyricsFound: Bool
    let createdAt: Date
}

enum AnalysisError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case networkError(String)
    case decodingError

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Inserisci la tua chiave API di Google AI Studio nelle impostazioni (icona ingranaggio in alto a destra)."
        case .invalidURL:
            return "URL non valido."
        case .networkError(let message):
            return message
        case .decodingError:
            return "Risposta del modello non leggibile. Riprova tra un attimo."
        }
    }
}

@MainActor
final class AnalysisService: ObservableObject {
    @Published var analysis: TrackAnalysis?
    @Published var isLoading = false
    @Published var isFromCache = false
    @Published var errorMessage: String?
    @Published var apiKey: String {
        didSet {
            UserDefaults.standard.set(
                apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                forKey: apiKeyStorageKey
            )
        }
    }

    private let apiKeyStorageKey = "musiclore_gemini_api_key"
    private let cachePrefix = "musiclore_cache_"

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init() {
        self.apiKey = UserDefaults.standard.string(forKey: "musiclore_gemini_api_key") ?? ""
    }

    func analyze(track: CurrentTrack, forceRefresh: Bool = false) async {
        errorMessage = nil
        let key = cacheKey(artist: track.artist, title: track.title)

        if !forceRefresh, let cached = loadFromCache(forKey: key) {
            self.analysis = cached
            self.isFromCache = true
            self.isLoading = false
            return
        }

        let cleanedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKey.isEmpty else {
            self.analysis = nil
            self.isFromCache = false
            self.errorMessage = AnalysisError.missingAPIKey.localizedDescription
            return
        }

        isLoading = true
        isFromCache = false
        analysis = nil

        do {
            let lyrics = await fetchLyrics(artist: track.artist, title: track.title, album: track.album)
            let result = try await requestGeminiAnalysis(track: track, lyrics: lyrics, apiKey: cleanedKey)
            saveToCache(result, forKey: key)
            self.analysis = result
            self.isLoading = false
        } catch {
            self.errorMessage = error.localizedDescription
            self.isLoading = false
        }
    }

    func clearCache() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(cachePrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - LRCLIB (Testo reale gratuito)

    private struct LRCLibResponse: Decodable {
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private func fetchLyrics(artist: String, title: String, album: String) async -> String? {
        var components = URLComponents(string: "https://lrclib.net/api/get")
        var items = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title)
        ]
        if !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        components?.queryItems = items

        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("MusicLore/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let decoded = try JSONDecoder().decode(LRCLibResponse.self, from: data)
            if let plain = decoded.plainLyrics, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return plain
            }
            if let synced = decoded.syncedLyrics, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return synced
            }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - Gemini API

    private struct GeminiRequest: Encodable {
        struct Content: Encodable {
            struct Part: Encodable {
                let text: String
            }
            let parts: [Part]
        }
        struct GenerationConfig: Encodable {
            struct Schema: Encodable {
                struct Property: Encodable {
                    let type: String
                }
                let type: String
                let properties: [String: Property]
                let required: [String]
            }
            let responseMimeType: String
            let responseSchema: Schema
        }
        let contents: [Content]
        let generationConfig: GenerationConfig
    }

    private struct GeminiResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable {
                    let text: String?
                }
                let parts: [Part]?
            }
            let content: Content?
        }
        struct APIError: Decodable {
            let message: String?
        }
        let candidates: [Candidate]?
        let error: APIError?
    }

    private struct ParsedGeminiJSON: Decodable {
        let storyAndReason: String
        let context: String
        let lyricsExplanation: String
    }

    private func requestGeminiAnalysis(track: CurrentTrack, lyrics: String?, apiKey: String) async throws -> TrackAnalysis {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw AnalysisError.invalidURL
        }

        let lyricsSection: String
        if let lyrics {
            lyricsSection = """
            Ecco il testo ufficiale del brano (usalo come riferimento principale per spiegare versi, immagini e metafore):
            ---
            \(lyrics)
            ---
            """
        } else {
            lyricsSection = """
            Il testo integrale non era disponibile nel database pubblico: basati sulla tua conoscenza accertata del brano senza inventare versi falsi. Se non conosci dettagli certi, segnalalo con onestà.
            """
        }

        let prompt = """
        Sei un critico musicale e storico della musica. Analizza in italiano, con tono chiaro, coinvolgente e concreto, il seguente brano:
        - Titolo: \(track.title)
        - Artista: \(track.artist)
        - Album: \(track.album.isEmpty ? "Non specificato" : track.album)

        \(lyricsSection)

        Restituisci un JSON con esattamente questi tre campi di testo (usa paragrafi ben separati con \\n\\n per renderli piacevoli da leggere su iPhone):
        1. "storyAndReason": la storia del brano, com'è nato e il motivo preciso per cui l'artista lo ha scritto (eventi personali, dediche, aneddoti di registrazione).
        2. "context": il contesto storico, culturale e della carriera dell'artista o dell'album in cui si inserisce il pezzo.
        3. "lyricsExplanation": spiegazione approfondita del significato del testo, dei temi principali, dei riferimenti nascosti e delle metafore più importanti.
        """

        let body = GeminiRequest(
            contents: [.init(parts: [.init(text: prompt)])],
            generationConfig: .init(
                responseMimeType: "application/json",
                responseSchema: .init(
                    type: "OBJECT",
                    properties: [
                        "storyAndReason": .init(type: "STRING"),
                        "context": .init(type: "STRING"),
                        "lyricsExplanation": .init(type: "STRING")
                    ],
                    required: ["storyAndReason", "context", "lyricsExplanation"]
                )
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let decoded = try? JSONDecoder().decode(GeminiResponse.self, from: data)

        if let apiError = decoded?.error?.message {
            throw AnalysisError.networkError("Errore Gemini API: \(apiError)")
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AnalysisError.networkError("Errore HTTP \(http.statusCode). Controlla la tua chiave API.")
        }

        guard let rawText = decoded?.candidates?.first?.content?.parts?.first?.text else {
            throw AnalysisError.decodingError
        }

        let cleanedJSON = rawText
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let jsonData = cleanedJSON.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(ParsedGeminiJSON.self, from: jsonData) else {
            throw AnalysisError.decodingError
        }

        return TrackAnalysis(
            storyAndReason: parsed.storyAndReason,
            context: parsed.context,
            lyricsExplanation: parsed.lyricsExplanation,
            lyricsFound: lyrics != nil,
            createdAt: Date()
        )
    }

    // MARK: - Cache Locale

    private func cacheKey(artist: String, title: String) -> String {
        let normalized = "\(artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))|\(title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
        return cachePrefix + normalized
    }

    private func saveToCache(_ item: TrackAnalysis, forKey key: String) {
        if let encoded = try? JSONEncoder().encode(item) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    private func loadFromCache(forKey key: String) -> TrackAnalysis? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(TrackAnalysis.self, from: data) else {
            return nil
        }
        return decoded
    }
}
