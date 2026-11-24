import Combine
import Foundation

struct VerifiedSource: Identifiable, Hashable, Codable {
    var id: String { url.absoluteString }
    let title: String
    let url: URL
}

struct TrackAnalysis: Codable, Equatable {
    let storyAndReason: String
    let context: String
    let lyricsExplanation: String
    let curiosities: String
    var lyricsFound: Bool
    var sources: [VerifiedSource]
    var webVerified: Bool
}

struct AlbumAnalysis: Codable, Equatable {
    let albumTitle: String
    let releaseDate: String
    let originAndStory: String
    let contextAndGoal: String
    let titleMeaning: String
    let curiosities: String
    var sources: [VerifiedSource]
    var webVerified: Bool
}

struct QAItem: Identifiable, Equatable {
    let id: UUID
    let question: String
    let answer: String
    let sources: [VerifiedSource]
    let webVerified: Bool

    init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        sources: [VerifiedSource],
        webVerified: Bool
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.sources = sources
        self.webVerified = webVerified
    }
}

private struct TrackAnalysisPayload: Decodable {
    let storyAndReason: String
    let context: String
    let lyricsExplanation: String
    let curiosities: String

    enum CodingKeys: String, CodingKey {
        case storyAndReason
        case context
        case lyricsExplanation
        case curiosities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.storyAndReason = try container.decodeIfPresent(String.self, forKey: .storyAndReason)?.nilIfBlank ?? "Informazioni sulla storia del brano non disponibili."
        self.context = try container.decodeIfPresent(String.self, forKey: .context)?.nilIfBlank ?? "Contesto non disponibile."
        self.lyricsExplanation = try container.decodeIfPresent(String.self, forKey: .lyricsExplanation)?.nilIfBlank ?? "Spiegazione del testo non disponibile."
        self.curiosities = try container.decodeIfPresent(String.self, forKey: .curiosities)?.nilIfBlank ?? "Nessuna curiosità confermata trovata nelle fonti online."
    }
}

private struct AlbumAnalysisPayload: Decodable {
    let albumTitle: String
    let releaseDate: String
    let originAndStory: String
    let contextAndGoal: String
    let titleMeaning: String
    let curiosities: String

    enum CodingKeys: String, CodingKey {
        case albumTitle
        case releaseDate
        case originAndStory
        case contextAndGoal
        case titleMeaning
        case curiosities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.albumTitle = try container.decodeIfPresent(String.self, forKey: .albumTitle)?.nilIfBlank ?? "Album"
        self.releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)?.nilIfBlank ?? "Data non disponibile"
        self.originAndStory = try container.decodeIfPresent(String.self, forKey: .originAndStory)?.nilIfBlank ?? "Nessuna informazione confermata sulla nascita dell'album."
        self.contextAndGoal = try container.decodeIfPresent(String.self, forKey: .contextAndGoal)?.nilIfBlank ?? "Nessuna informazione confermata sul contesto."
        self.titleMeaning = try container.decodeIfPresent(String.self, forKey: .titleMeaning)?.nilIfBlank ?? "Nessuna informazione confermata sul significato del titolo."
        self.curiosities = try container.decodeIfPresent(String.self, forKey: .curiosities)?.nilIfBlank ?? "Nessuna curiosità confermata disponibile."
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
    }

    struct Tool: Encodable {
        struct GoogleSearch: Encodable {}
        let google_search: GoogleSearch
    }

    let contents: [Content]
    let generationConfig: GenerationConfig
    let tools: [Tool]
}

private struct GeminiResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
            }
            let parts: [Part]?
        }

        struct GroundingMetadata: Decodable {
            struct GroundingChunk: Decodable {
                struct Web: Decodable {
                    let uri: String?
                    let title: String?
                }
                let web: Web?
            }

            struct GroundingSupport: Decodable {
                let groundingChunkIndices: [Int]?
            }

            struct SearchEntryPoint: Decodable {
                let renderedContent: String?
            }

            let webSearchQueries: [String]?
            let groundingChunks: [GroundingChunk]?
            let groundingSupports: [GroundingSupport]?
            let searchEntryPoint: SearchEntryPoint?
        }

        let content: Content?
        let groundingMetadata: GroundingMetadata?
    }

    struct APIError: Decodable {
        let code: Int?
        let message: String?
    }

    let candidates: [Candidate]?
    let error: APIError?
}

private struct GeminiResult {
    let text: String
    let sources: [VerifiedSource]
    let usedWebSearch: Bool
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

    // Stato domande specifiche (Q&A)
    @Published var qaByTrack: [String: [QAItem]] = [:]
    @Published var isAnsweringQuestion = false
    @Published var qaErrorMessage: String?

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let apiKeyStorageKey = "gemini_api_key"
    private static let trackCacheStorageKey = "musiclore_track_cache_v3"
    private static let albumCacheStorageKey = "musiclore_album_cache_v2"

    // Modelli aggiornati con supporto Google Search Grounding
    private let geminiSearchModels = [
        "gemini-3.8-flash",
        "gemini-flash-latest",
        "gemini-3-flash-preview",
        "gemini-3.5-flash-lite",
        "gemini-3.1-flash-lite",
        "gemini-flash-lite-latest"
    ]

    private var trackCache: [String: TrackAnalysis] = [:]
    private var albumCache: [String: AlbumAnalysis] = [:]
    private var lyricsCache: [String: String] = [:]
    private var activeTrackKey: String?
    private var activeAlbumKey: String?

    init() {
        self.apiKey = UserDefaults.standard.string(forKey: Self.apiKeyStorageKey) ?? ""
        self.trackCache = Self.loadCache(forKey: Self.trackCacheStorageKey)
        self.albumCache = Self.loadCache(forKey: Self.albumCacheStorageKey)
    }

    func qaItems(for track: CurrentTrack) -> [QAItem] {
        qaByTrack[track.id] ?? []
    }

    func clearQA(for track: CurrentTrack) {
        qaByTrack[track.id] = []
        qaErrorMessage = nil
    }

    func clearCache() {
        trackCache.removeAll()
        albumCache.removeAll()
        lyricsCache.removeAll()
        qaByTrack.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.trackCacheStorageKey)
        UserDefaults.standard.removeObject(forKey: Self.albumCacheStorageKey)
        analysis = nil
        albumAnalysis = nil
        isFromCache = false
        isAlbumFromCache = false
        qaErrorMessage = nil
        activeTrackKey = nil
        activeAlbumKey = nil
    }

    // MARK: - Analisi Canzone (sempre con ricerca web)

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
        if let lyrics {
            lyricsCache[key] = lyrics
        }
        let prompt = buildTrackPrompt(track: track, lyrics: lyrics)

        do {
            let (decoded, sources) = try await callGeminiJSONWithWebSearch(
                as: TrackAnalysisPayload.self,
                prompt: prompt,
                apiKey: trimmedKey,
                temperature: 0.2
            )
            let result = TrackAnalysis(
                storyAndReason: decoded.storyAndReason,
                context: decoded.context,
                lyricsExplanation: decoded.lyricsExplanation,
                curiosities: decoded.curiosities,
                lyricsFound: lyrics != nil,
                sources: sources,
                webVerified: true
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

    // MARK: - Analisi Album (sempre con ricerca web)

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
            let (decoded, sources) = try await callGeminiJSONWithWebSearch(
                as: AlbumAnalysisPayload.self,
                prompt: prompt,
                apiKey: trimmedKey,
                temperature: 0.2
            )
            let result = AlbumAnalysis(
                albumTitle: decoded.albumTitle,
                releaseDate: decoded.releaseDate,
                originAndStory: decoded.originAndStory,
                contextAndGoal: decoded.contextAndGoal,
                titleMeaning: decoded.titleMeaning,
                curiosities: decoded.curiosities,
                sources: sources,
                webVerified: true
            )

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

    // MARK: - Domande specifiche (sempre con ricerca web obbligatoria)

    func askQuestion(_ rawQuestion: String, for track: CurrentTrack, focusCategory: String) async {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            qaErrorMessage = "Inserisci la tua Gemini API Key nelle Impostazioni (icona ingranaggio in alto a destra)."
            return
        }

        qaErrorMessage = nil
        isAnsweringQuestion = true
        defer { isAnsweringQuestion = false }

        let previousItems = Array((qaByTrack[track.id] ?? []).suffix(4))
        let lyrics = lyricsCache[track.id]
        let prompt = buildQuestionPrompt(
            question: question,
            track: track,
            focusCategory: focusCategory,
            lyrics: lyrics,
            history: previousItems
        )

        do {
            let result = try await callGeminiTextWithWebSearch(
                prompt: prompt,
                apiKey: trimmedKey,
                temperature: 0.15
            )
            let cleanedAnswer = cleanPlainTextAnswer(result.text)
            let item = QAItem(
                question: question,
                answer: cleanedAnswer,
                sources: result.sources,
                webVerified: result.usedWebSearch
            )
            qaByTrack[track.id, default: []].append(item)
            qaErrorMessage = nil
        } catch {
            qaErrorMessage = error.localizedDescription
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
            lyricsSection = "Testo non trovato su LRCLib: cerca online interviste, recensioni e analisi attendibili senza inventare versi o citazioni inesistenti."
        }

        return """
        OBBLIGATORIO: Prima di scrivere la risposta DEVI eseguire almeno una ricerca Google con lo strumento google_search per verificare storia, interviste, crediti di produzione, sample e curiosità reali su questo brano. Non rispondere mai solo a memoria.

        Sei un ricercatore musicale rigoroso. Analizza in italiano il seguente brano basandoti su fonti verificate, senza inventare nulla (se un dettaglio non è confermato da fonti affidabili, dillo chiaramente).

        Titolo: \(track.title)
        Artista: \(track.artist)
        Album: \(albumLine)

        \(lyricsSection)

        Restituisci ESCLUSIVAMENTE un oggetto JSON valido (nessun testo prima o dopo le parentesi graffe, nessun Markdown, nessun carattere di a capo non escapato dentro le stringhe) con queste 4 chiavi esatte:
        {
          "storyAndReason": "Come nasce il brano, perché è stato scritto, ispirazione e storia verificata della creazione.",
          "context": "Il contesto personale, artistico, culturale o storico in cui si inserisce il brano nella carriera dell'artista.",
          "lyricsExplanation": "Spiegazione chiara del significato del testo, dei temi principali, delle immagini e delle metafore chiave.",
          "curiosities": "Curiosità verificate, retroscena di registrazione, produttori, sample/campionamenti, collaborazioni o dichiarazioni reali in interviste."
        }
        """
    }

    private func buildAlbumPrompt(track: CurrentTrack) -> String {
        let albumInstruction: String
        if track.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            albumInstruction = "L'album non è indicato nei metadati: cerca online l'album o EP di appartenenza del brano \"\(track.title)\" di \(track.artist) (oppure, se è un singolo autonomo, specificalo chiaramente e racconta il progetto/era discografica in cui è uscito)."
        } else {
            albumInstruction = "Album: \(track.album) (brano attualmente in ascolto: \(track.title))."
        }

        return """
        OBBLIGATORIO: Prima di scrivere la risposta DEVI eseguire almeno una ricerca Google con lo strumento google_search per verificare la data di uscita esatta, la genesi, i produttori, le interviste e le curiosità reali dell'album. Non rispondere mai solo a memoria.

        Sei un ricercatore musicale rigoroso. Racconta in italiano la storia completa dell'album in modo accurato e basato su fonti confermate, senza inventare nulla.

        Artista: \(track.artist)
        \(albumInstruction)

        Restituisci ESCLUSIVAMENTE un oggetto JSON valido (nessun testo prima o dopo le parentesi graffe, nessun Markdown, nessun carattere di a capo non escapato dentro le stringhe) con queste 6 chiavi esatte:
        {
          "albumTitle": "Titolo ufficiale dell'album o EP.",
          "releaseDate": "Data di uscita verificata in italiano (es. '12 novembre 2021').",
          "originAndStory": "La storia completa di come nasce l'intero album: genesi, periodo di scrittura, registrazione, scelte sonore e produttori.",
          "contextAndGoal": "Il contesto storico e artistico in cui esce il disco e qual era l'obiettivo, il concept o il messaggio generale dell'intero progetto.",
          "titleMeaning": "Il significato del titolo dell'album e, se rilevante, il legame con la copertina o con il filo conduttore del disco.",
          "curiosities": "Curiosità verificate, retroscena, collaborazioni particolari, impatto o aneddoti reali legati all'album."
        }
        """
    }

    private func buildQuestionPrompt(
        question: String,
        track: CurrentTrack,
        focusCategory: String,
        lyrics: String?,
        history: [QAItem]
    ) -> String {
        let albumLine = track.album.isEmpty ? "Non specificato" : track.album
        let historyBlock: String
        if history.isEmpty {
            historyBlock = ""
        } else {
            let lines = history.map { "Utente: \($0.question)\nAssistente: \($0.answer)" }.joined(separator: "\n\n")
            historyBlock = "\nDomande precedenti su questo brano:\n\(lines)\n"
        }

        let lyricsHint: String
        if let lyrics {
            lyricsHint = "\nEstratto del testo verificato del brano (utile se la domanda riguarda versi specifici):\n\"\"\"\n\(String(lyrics.prefix(3500)))\n\"\"\"\n"
        } else {
            lyricsHint = ""
        }

        return """
        OBBLIGATORIO: Prima di formulare qualsiasi risposta DEVI eseguire sempre una ricerca web con lo strumento google_search cercando interviste, articoli, crediti e fonti reali sul brano o sull'album. È vietato rispondere solo a memoria senza cercare online.

        Contesto attuale:
        - Categoria attiva nell'app: \(focusCategory)
        - Brano: \(track.title)
        - Artista: \(track.artist)
        - Album: \(albumLine)
        \(lyricsHint)\(historyBlock)
        REGOLE OBBLIGATORIE DI VERIFICA:
        1. Cerca sul web con google_search e incrocia le fonti (interviste ufficiali, testate musicali, crediti discografici, Genius/Wikipedia solo se coerenti con fonti primarie).
        2. Conferma solo ciò che risulta dalle fonti trovate. Se un dettaglio non trova conferme online, scrivilo chiaramente ("Non risultano conferme ufficiali online su questo punto") senza inventare nulla.
        3. Rispondi in italiano in modo diretto, chiaro e in testo semplice (niente asterischi Markdown come **grassetto**).

        Domanda dell'utente:
        \(question)
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

    // MARK: - Chiamata Gemini con Google Search obbligatorio

    private func callGeminiJSONWithWebSearch<T: Decodable>(
        as type: T.Type,
        prompt: String,
        apiKey: String,
        temperature: Double
    ) async throws -> (T, [VerifiedSource]) {
        var failures: [String] = []

        for model in geminiSearchModels {
            do {
                let result = try await callGeminiWithSearch(
                    model: model,
                    prompt: prompt,
                    apiKey: apiKey,
                    temperature: temperature
                )
                let cleanedJSON = sanitizeJSONControlCharacters(extractJSONObject(from: result.text))
                guard let data = cleanedJSON.data(using: .utf8) else {
                    throw ServiceError.retryable("[\(model)] JSON non leggibile.")
                }
                let decoded = try JSONDecoder().decode(T.self, from: data)
                return (decoded, result.sources)
            } catch let serviceError as ServiceError {
                if case .fatal(let message) = serviceError {
                    throw ServiceError.fatal(message)
                }
                failures.append(serviceError.localizedDescription)
            } catch {
                failures.append("[\(model)] Formato JSON non valido: \(error.localizedDescription)")
            }
        }

        let summary = failures.joined(separator: "\n• ")
        throw ServiceError.invalidResponse("Ricerca web obbligatoria non riuscita:\n• \(summary)")
    }

    private func callGeminiTextWithWebSearch(
        prompt: String,
        apiKey: String,
        temperature: Double
    ) async throws -> GeminiResult {
        var failures: [String] = []

        for model in geminiSearchModels {
            do {
                return try await callGeminiWithSearch(
                    model: model,
                    prompt: prompt,
                    apiKey: apiKey,
                    temperature: temperature
                )
            } catch let serviceError as ServiceError {
                if case .fatal(let message) = serviceError {
                    throw ServiceError.fatal(message)
                }
                failures.append(serviceError.localizedDescription)
            } catch {
                failures.append("[\(model)] \(error.localizedDescription)")
            }
        }

        let summary = failures.joined(separator: "\n• ")
        throw ServiceError.invalidResponse("Ricerca web obbligatoria non riuscita:\n• \(summary)")
    }

    private func callGeminiWithSearch(
        model: String,
        prompt: String,
        apiKey: String,
        temperature: Double
    ) async throws -> GeminiResult {
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        guard let url = components?.url else {
            throw ServiceError.fatal("URL API non valido.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 40
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = GeminiRequest(
            contents: [.init(parts: [.init(text: prompt)])],
            generationConfig: .init(temperature: temperature),
            tools: [.init(google_search: .init())]
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.retryable("[\(model)] Risposta di rete non valida.")
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
        guard let candidate = decoded.candidates?.first,
              let text = candidate.content?.parts?.compactMap(\.text).joined().nilIfBlank else {
            throw ServiceError.retryable("[\(model)] Risposta vuota.")
        }

        var seenURLs = Set<String>()
        var sources: [VerifiedSource] = []
        let metadata = candidate.groundingMetadata

        for chunk in metadata?.groundingChunks ?? [] {
            guard let rawURI = chunk.web?.uri?.nilIfBlank,
                  let sourceURL = URL(string: rawURI),
                  let scheme = sourceURL.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https"),
                  !seenURLs.contains(sourceURL.absoluteString) else {
                continue
            }
            seenURLs.insert(sourceURL.absoluteString)
            let label = chunk.web?.title?.nilIfBlank ?? sourceURL.host ?? "Fonte web"
            sources.append(VerifiedSource(title: label, url: sourceURL))
        }

        let hasQueries = !(metadata?.webSearchQueries?.isEmpty ?? true)
        let hasSupports = !(metadata?.groundingSupports?.isEmpty ?? true)
        let hasEntryPoint = metadata?.searchEntryPoint?.renderedContent?.nilIfBlank != nil
        let didSearch = !sources.isEmpty || hasQueries || hasSupports || hasEntryPoint

        guard didSearch else {
            throw ServiceError.retryable("[\(model)] Ha risposto senza eseguire la ricerca Google.")
        }

        return GeminiResult(
            text: text,
            sources: sources,
            usedWebSearch: true
        )
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

    private func sanitizeJSONControlCharacters(_ json: String) -> String {
        var result = ""
        result.reserveCapacity(json.count)
        var inString = false
        var escaped = false

        for ch in json {
            if inString {
                if escaped {
                    result.append(ch)
                    escaped = false
                } else if ch == "\\" {
                    result.append(ch)
                    escaped = true
                } else if ch == "\"" {
                    result.append(ch)
                    inString = false
                } else if ch == "\n" || ch == "\r" || ch == "\r\n" {
                    result.append("\\n")
                } else if ch == "\t" {
                    result.append("\\t")
                } else {
                    result.append(ch)
                }
            } else {
                if ch == "\"" {
                    inString = true
                }
                result.append(ch)
            }
        }
        return result
    }

    private func cleanPlainTextAnswer(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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