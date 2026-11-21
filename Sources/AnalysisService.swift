import Combine
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

    // Modelli verificati come attivi sulla chiave, in ordine di priorità
    private let candidateModels = [
        "gemini-3.5-flash-lite",
        "gemini-flash-lite-latest",
        "gemini-3.1-flash-lite",
        "gemini-3-flash-preview"
    ]

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
            let result = try await requestGeminiWithFallback(track: track, lyrics: lyrics, apiKey: cleanedKey)
            saveToCache(result, forKey: key)
            self.analysis = result
            self.isLoading = false
        } catch is CancellationError {
            self.isLoading = false
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                self.isLoading = false
                return
            }
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

    // MARK: - LRCLIB

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
        request.timeoutInterval = 6
        request.assumesHTTP3Capable = false
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

    private enum AttemptError: Error {
        case retryable(Error)
        case fatal(Error)
    }

    private struct GeminiRequest: Encodable {
        struct Content: Encodable {
            struct Part: Encodable {
                let text: String
            }
            let parts: [Part]
        }
        struct GenerationConfig: Encodable {
            let responseMimeType: String
            let maxOutputTokens: Int
            let temperature: Double
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

    private func requestGeminiWithFallback(track: CurrentTrack, lyrics: String?, apiKey: String) async throws -> TrackAnalysis {
        var lastError: Error = AnalysisError.networkError("Nessun modello Gemini disponibile al momento. Riprova tra poco.")

        for model in candidateModels {
            try Task.checkCancellation()
            do {
                return try await requestSingleModel(model: model, track: track, lyrics: lyrics, apiKey: apiKey)
            } catch AttemptError.fatal(let error) {
                throw error
            } catch AttemptError.retryable(let error) {
                lastError = error
                continue
            } catch {
                if error is CancellationError {
                    throw error
                }
                if let urlError = error as? URLError, urlError.code == .cancelled {
                    throw error
                }
                lastError = error
                continue
            }
        }

        throw lastError
    }

    private func requestSingleModel(model: String, track: CurrentTrack, lyrics: String?, apiKey: String) async throws -> TrackAnalysis {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw AttemptError.fatal(AnalysisError.invalidURL)
        }

        let lyricsSection: String
        if let lyrics {
            let trimmedLyrics = String(lyrics.prefix(3500))
            lyricsSection = """
            Testo del brano:
            \(trimmedLyrics)
            """
        } else {
            lyricsSection = "Testo non disponibile: basati solo su informazioni certe senza inventare versi."
        }

        let prompt = """
        Sei un critico musicale. Analizza in italiano, in modo chiaro e sintetico, questo brano:
        Titolo: \(track.title)
        Artista: \(track.artist)
        Album: \(track.album.isEmpty ? "Non specificato" : track.album)

        \(lyricsSection)

        Rispondi SOLO con un oggetto JSON valido con queste 3 chiavi esatte (massimo 100 parole per chiave):
        {
          "storyAndReason": "storia del brano e motivo per cui è stato scritto",
          "context": "contesto storico, culturale e della carriera dell'artista",
          "lyricsExplanation": "spiegazione del significato del testo e delle metafore principali"
        }
        """

        let body = GeminiRequest(
            contents: [.init(parts: [.init(text: prompt)])],
            generationConfig: .init(
                responseMimeType: "application/json",
                maxOutputTokens: 1500,
                temperature: 0.5
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.assumesHTTP3Capable = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        let decoded = try? JSONDecoder().decode(GeminiResponse.self, from: data)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if statusCode == 401 || statusCode == 403 {
            let msg = decoded?.error?.message ?? "Chiave API non valida o non autorizzata (HTTP \(statusCode))."
            throw AttemptError.fatal(AnalysisError.networkError(msg))
        }

        if !(200...299).contains(statusCode) {
            let msg = decoded?.error?.message ?? "Errore HTTP \(statusCode) sul modello \(model)."
            throw AttemptError.retryable(AnalysisError.networkError(msg))
        }

        guard let rawText = decoded?.candidates?.first?.content?.parts?.first?.text else {
            throw AttemptError.retryable(AnalysisError.decodingError)
        }

        let cleaned = rawText
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let jsonString: String
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}") {
            jsonString = String(cleaned[start...end])
        } else {
            jsonString = cleaned
        }

        guard let jsonData = jsonString.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(ParsedGeminiJSON.self, from: jsonData) else {
            throw AttemptError.retryable(AnalysisError.decodingError)
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