import Combine
import Foundation

struct TrackAnalysis: Codable, Equatable {
    let storyAndReason: String
    let context: String
    let lyricsExplanation: String
    var lyricsFound: Bool
}

struct AlbumAnalysis: Codable, Equatable {
    let albumTitle: String
    let releaseDate: String
    let originAndStory: String
    let contextAndGoal: String
    let titleMeaning: String
    let curiosities: String

    init(
        albumTitle: String,
        releaseDate: String,
        originAndStory: String,
        contextAndGoal: String,
        titleMeaning: String,
        curiosities: String
    ) {
        self.albumTitle = albumTitle
        self.releaseDate = releaseDate
        self.originAndStory = originAndStory
        self.contextAndGoal = contextAndGoal
        self.titleMeaning = titleMeaning
        self.curiosities = curiosities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.albumTitle = try container.decodeIfPresent(String.self, forKey: .albumTitle)?.nilIfBlank ?? "Album"
        self.releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)?.nilIfBlank ?? "Data non disponibile"
        self.originAndStory = try container.decodeIfPresent(String.self, forKey: .originAndStory)?.nilIfBlank ?? "Nessuna informazione disponibile sulla nascita dell'album."
        self.contextAndGoal = try container.decodeIfPresent(String.self, forKey: .contextAndGoal)?.nilIfBlank ?? "Nessuna informazione disponibile sul contesto."
        self.titleMeaning = try container.decodeIfPresent(String.self, forKey: .titleMeaning)?.nilIfBlank ?? "Nessuna informazione disponibile sul significato del titolo."
        self.curiosities = try container.decodeIfPresent(String.self, forKey: .curiosities)?.nilIfBlank ?? "Nessuna curiosità disponibile."
    }
}

private struct TrackAnalysisPayload: Decodable {
    let storyAndReason: String
    let context: String
    let lyricsExplanation: String

    enum CodingKeys: String, CodingKey {
        case storyAndReason
        case context
        case lyricsExplanation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.storyAndReason = try container.decodeIfPresent(String.self, forKey: .storyAndReason)?.nilIfBlank ?? "Informazioni sulla storia del brano non disponibili."
        self.context = try container.decodeIfPresent(String.self, forKey: .context)?.nilIfBlank ?? "Contesto non disponibile."
        self.lyricsExplanation = try container.decodeIfPresent(String.self, forKey: .lyricsExplanation)?.nilIfBlank ?? "Spiegazione del testo non disponibile."
    }
}

private struct LRCLibResponse: Decodable {
    let plainLyrics: String?
    let syncedLyrics: String?
}

private struct GeminiRequest: Encodable {
    struct Content: Encodable {
        struct Part: Encodable {
            let text: String
        }
        let parts: [Part]
    }

    struct GenerationConfig: Encodable {
        let temperature: Double
        let responseMimeType: String
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
        let code: Int?
        let message: String?
    }

    let candidates: [Candidate]?
    let error: APIError?
}

@MainActor
final class AnalysisService: ObservableObject {
    @Published var apiKey: String {
        didSet {
            UserDefaults.standard.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.apiKeyStorageKey)
        }
    }

    // Stato analisi canzone
    @Published var analysis: TrackAnalysis?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isFromCache = false

    // Stato analisi album
    @Published var albumAnalysis: AlbumAnalysis?
    @Published var isLoadingAlbum = false
    @Published var albumErrorMessage: String?
    @Published var isAlbumFromCache = false

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let apiKeyStorageKey = "gemini_api_key"
    private static let trackCacheStorageKey = "musiclore_track_cache_v1"
    private static let albumCacheStorageKey = "musiclore_album_cache_v1"

    private let geminiModels = [
        "gemini-3.5-flash-lite",
        "gemini-flash-lite-latest",
        "gemini-3.1-flash-lite",
        "gemini-3-flash-preview"
    ]

    private var trackCache: [String: TrackAnalysis] = [:]
    private var albumCache: [String: AlbumAnalysis] = [:]
    private var activeTrackKey: String?
    private var activeAlbumKey: String?

    init() {
        self.apiKey = UserDefaults.standard.string(forKey: Self.apiKeyStorageKey) ?? ""
        self.trackCache = Self.loadCache(forKey: Self.trackCacheStorageKey)
        self.albumCache = Self.loadCache(forKey: Self.albumCacheStorageKey)
    }

    func clearCache() {
        trackCache.removeAll()
        albumCache.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.trackCacheStorageKey)
        UserDefaults.standard.removeObject(forKey: Self.albumCacheStorageKey)
        analysis = nil
        albumAnalysis = nil
        isFromCache = false
        isAlbumFromCache = false
        activeTrackKey = nil
        activeAlbumKey = nil
    }

    // MARK: - Analisi Canzone

    func analyze(track: CurrentTrack, forceRefresh: Bool = false) async {
        let key = track.id

        if !forceRefresh, activeTrackKey == key, analysis != nil {
            return
        }

        activeTrackKey = key
        errorMessage = nil

        if !forceRefresh, let cached = trackCache[key] {
            analysis = cached
            isFromCache = true
            isLoading = false
            return
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            analysis = nil
            isFromCache = false
            isLoading = false
            errorMessage = "Inserisci la tua Gemini API Key nelle Impostazioni (icona ingranaggio in alto a destra)."
            return
        }

        isLoading = true
        isFromCache = false
        analysis = nil

        let lyrics = await fetchLyrics(track: track)
        let prompt = buildTrackPrompt(track: track, lyrics: lyrics)

        do {
            let rawJSON = try await callGeminiWithFallback(prompt: prompt, apiKey: trimmedKey)
            let cleanedJSON = extractJSONObject(from: rawJSON)
            guard let data = cleanedJSON.data(using: .utf8) else {
                throw ServiceError.invalidResponse("Risposta non leggibile dal modello.")
            }
            let decoded = try JSONDecoder().decode(TrackAnalysisPayload.self, from: data)
            let result = TrackAnalysis(
                storyAndReason: decoded.storyAndReason,
                context: decoded.context,
                lyricsExplanation: decoded.lyricsExplanation,
                lyricsFound: lyrics != nil
            )

            guard activeTrackKey == key else { return }
            trackCache[key] = result
            Self.saveCache(trackCache, forKey: Self.trackCacheStorageKey)
            analysis = result
            isFromCache = false
            errorMessage = nil
        } catch {
            guard activeTrackKey == key else { return }
            errorMessage = error.localizedDescription
        }

        if activeTrackKey == key {
            isLoading = false
        }
    }

    // MARK: - Analisi Album

    func analyzeAlbum(track: CurrentTrack, forceRefresh: Bool = false) async {
        let key = albumCacheKey(for: track)

        if !forceRefresh, activeAlbumKey == key, albumAnalysis != nil {
            return
        }

        activeAlbumKey = key
        albumErrorMessage = nil

        if !forceRefresh, let cached = albumCache[key] {
            albumAnalysis = cached
            isAlbumFromCache = true
            isLoadingAlbum = false
            return
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            albumAnalysis = nil
            isAlbumFromCache = false
            isLoadingAlbum = false
            albumErrorMessage = "Inserisci la tua Gemini API Key nelle Impostazioni (icona ingranaggio in alto a destra)."
            return
        }

        isLoadingAlbum = true
        isAlbumFromCache = false
        albumAnalysis = nil

        let prompt = buildAlbumPrompt(track: track)

        do {
            let rawJSON = try await callGeminiWithFallback(prompt: prompt, apiKey: trimmedKey)
            let cleanedJSON = extractJSONObject(from: rawJSON)
            guard let data = cleanedJSON.data(using: .utf8) else {
                throw ServiceError.invalidResponse("Risposta non leggibile dal modello.")
            }
            let result = try JSONDecoder().decode(AlbumAnalysis.self, from: data)

            guard activeAlbumKey == key else { return }
            albumCache[key] = result
            Self.saveCache(albumCache, forKey: Self.albumCacheStorageKey)
            albumAnalysis = result
            isAlbumFromCache = false
            albumErrorMessage = nil
        } catch {
            guard activeAlbumKey == key else { return }
            albumErrorMessage = error.localizedDescription
        }

        if activeAlbumKey == key {
            isLoadingAlbum = false
        }
    }

    // MARK: - Prompt

    private func buildTrackPrompt(track: CurrentTrack, lyrics: String?) -> String {
        let albumLine = track.album.isEmpty ? "Non specificato" : track.album
        let lyricsSection: String
        if let lyrics {
            let clipped = String(lyrics.prefix(6000))
            lyricsSection = """
            Testo verificato del brano:
            \"\"\"
            \(clipped)
            \"\"\"
            """
        } else {
            lyricsSection = "Testo non trovato su LRCLib: basati sulle tue conoscenze affidabili senza inventare versi o citazioni inesistenti."
        }

        return """
        Sei un esperto di storia della musica e critica musicale. Analizza in italiano il seguente brano in modo coinvolgente, chiaro e concreto, senza invenzioni.

        Titolo: \(track.title)
        Artista: \(track.artist)
        Album: \(albumLine)

        \(lyricsSection)

        Restituisci ESCLUSIVAMENTE un oggetto JSON valido con queste 3 chiavi esatte (valori in testo semplice, senza Markdown o asterischi):
        {
          "storyAndReason": "Come nasce il brano, perché è stato scritto, aneddoti sulla creazione o registrazione.",
          "context": "Il contesto personale, artistico, culturale o storico in cui si inserisce il brano nella carriera dell'artista.",
          "lyricsExplanation": "Spiegazione chiara del significato del testo, dei temi principali, delle immagini e delle metafore chiave."
        }
        """
    }

    private func buildAlbumPrompt(track: CurrentTrack) -> String {
        let albumInstruction: String
        if track.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            albumInstruction = "L'album non è indicato nei metadati: identifica l'album o EP di appartenenza del brano \"\(track.title)\" di \(track.artist) (oppure, se è un singolo autonomo, specificalo chiaramente e racconta il progetto/era discografica in cui è uscito)."
        } else {
            albumInstruction = "Album: \(track.album) (brano attualmente in ascolto: \(track.title))."
        }

        return """
        Sei un esperto di storia della musica e critica musicale. Racconta in italiano la storia completa dell'album in modo ricco, scorrevole e accurato, senza inventare dettagli non verificati.

        Artista: \(track.artist)
        \(albumInstruction)

        Restituisci ESCLUSIVAMENTE un oggetto JSON valido con queste 6 chiavi esatte (valori in testo semplice, senza Markdown o asterischi):
        {
          "albumTitle": "Titolo ufficiale dell'album o EP (es. 'Mr. Simpatia').",
          "releaseDate": "Data di uscita in italiano (es. '12 novembre 2021', oppure solo mese/anno se il giorno esatto non è noto).",
          "originAndStory": "La storia completa di come nasce l'intero album: genesi, periodo di scrittura, registrazione, scelte sonore e produttori.",
          "contextAndGoal": "Il contesto storico e artistico in cui esce il disco e qual era l'obiettivo, il concept o il messaggio generale dell'intero progetto.",
          "titleMeaning": "Il significato del titolo dell'album e, se rilevante, il legame con la copertina o con il filo conduttore del disco.",
          "curiosities": "Curiosità, retroscena, collaborazioni particolari, impatto o aneddoti interessanti legati all'album."
        }
        """
    }

    // MARK: - LRCLib

    private func fetchLyrics(track: CurrentTrack) async -> String? {
        if let exact = await queryLRCLibGet(track: track) {
            return exact
        }
        return await queryLRCLibSearch(track: track)
    }

    private func queryLRCLibGet(track: CurrentTrack) async -> String? {
        var components = URLComponents(string: "https://lrclib.net/api/get")
        var items = [
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "track_name", value: track.title)
        ]
        if !track.album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: track.album))
        }
        components?.queryItems = items

        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            let item = try JSONDecoder().decode(LRCLibResponse.self, from: data)
            return extractLyricsText(from: item)
        } catch {
            return nil
        }
    }

    private func queryLRCLibSearch(track: CurrentTrack) async -> String? {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "track_name", value: track.title)
        ]

        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            let results = try JSONDecoder().decode([LRCLibResponse].self, from: data)
            for item in results {
                if let text = extractLyricsText(from: item) {
                    return text
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    private func extractLyricsText(from item: LRCLibResponse) -> String? {
        if let plain = item.plainLyrics?.nilIfBlank {
            return plain
        }
        if let synced = item.syncedLyrics?.nilIfBlank {
            let stripped = synced
                .replacingOccurrences(of: #"\[[^\]]+\]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stripped.nilIfBlank
        }
        return nil
    }

    // MARK: - Chiamata Gemini con fallback

    private func callGeminiWithFallback(prompt: String, apiKey: String) async throws -> String {
        var lastError: Error = ServiceError.invalidResponse("Nessun modello Gemini ha risposto.")

        for model in geminiModels {
            do {
                return try await callGemini(model: model, prompt: prompt, apiKey: apiKey)
            } catch let serviceError as ServiceError {
                if case .fatal(let message) = serviceError {
                    throw ServiceError.fatal(message)
                }
                lastError = serviceError
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    private func callGemini(model: String, prompt: String, apiKey: String) async throws -> String {
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        guard let url = components?.url else {
            throw ServiceError.fatal("URL API non valido.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = GeminiRequest(
            contents: [.init(parts: [.init(text: prompt)])],
            generationConfig: .init(temperature: 0.4, responseMimeType: "application/json")
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.retryable("Risposta di rete non valida.")
        }

        if !(200...299).contains(http.statusCode) {
            let apiMessage = (try? JSONDecoder().decode(GeminiResponse.self, from: data))?.error?.message
            let detail = apiMessage ?? "Errore HTTP \(http.statusCode)"

            if http.statusCode == 400 || http.statusCode == 401 || http.statusCode == 403 {
                if detail.lowercased().contains("api key") || detail.lowercased().contains("permission") {
                    throw ServiceError.fatal("API Key non valida o non autorizzata (\(detail)).")
                }
            }
            throw ServiceError.retryable("[\(model)] \(detail)")
        }

        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        guard let text = decoded.candidates?.first?.content?.parts?.compactMap(\.text).joined().nilIfBlank else {
            throw ServiceError.retryable("[\(model)] Risposta vuota.")
        }
        return text
    }

    // MARK: - Utilità

    private func albumCacheKey(for track: CurrentTrack) -> String {
        let artist = track.artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let album = track.album.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if !album.isEmpty {
            return "album|\(artist)|\(album)"
        }
        let title = track.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return "single|\(artist)|\(title)"
    }

    private func extractJSONObject(from raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.replacingOccurrences(of: #"^```[a-zA-Z]*\s*"#, with: "", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        if let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}") {
            return String(cleaned[start...end])
        }
        return cleaned
    }

    private static func loadCache<T: Decodable>(forKey key: String) -> [String: T] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: T].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func saveCache<T: Encodable>(_ cache: [String: T], forKey key: String) {
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

private enum ServiceError: LocalizedError {
    case retryable(String)
    case fatal(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .retryable(let message), .fatal(let message), .invalidResponse(let message):
            return message
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}