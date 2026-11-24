import Combine
import Foundation

struct VerifiedSource: Identifiable, Hashable, Codable, Sendable {
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
    var sourceSummary: String
}

struct AlbumAnalysis: Codable, Equatable {
    let albumTitle: String
    let releaseDate: String
    let originAndStory: String
    let contextAndGoal: String
    let titleMeaning: String
    let curiosities: String
    var sources: [VerifiedSource]
    var sourceSummary: String
}

struct QAItem: Identifiable, Equatable {
    let id: UUID
    let question: String
    let answer: String
    let sources: [VerifiedSource]
    let sourceSummary: String

    init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        sources: [VerifiedSource],
        sourceSummary: String
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.sources = sources
        self.sourceSummary = sourceSummary
    }
}

private struct WebEvidence: Sendable {
    let source: VerifiedSource
    let snippet: String
    let provider: String
}

private struct WebBundle: Sendable {
    let evidences: [WebEvidence]
    let sources: [VerifiedSource]
    let summary: String
    let notice: String?

    var promptContext: String {
        guard !evidences.isEmpty else {
            return "Nessuna pagina web pertinente trovata automaticamente. Basati solo su informazioni realmente note e segnala chiaramente qualsiasi dettaglio non confermato."
        }
        return evidences.enumerated().map { idx, item in
            """
            [FONTE \(idx + 1) - \(item.provider)] \(item.source.title)
            URL: \(item.source.url.absoluteString)
            Estratto:
            \(item.snippet)
            """
        }.joined(separator: "\n\n")
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
        self.curiosities = try container.decodeIfPresent(String.self, forKey: .curiosities)?.nilIfBlank ?? "Nessuna curiosità confermata trovata nelle fonti consultate."
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
        self.curiosities = try container.decodeIfPresent(String.self, forKey: .curiosities)?.nilIfBlank ?? "Nessuna curiosità confermata trovata nelle fonti consultate."
    }
}

private struct LRCLibResponse: Decodable {
    let plainLyrics: String?
    let syncedLyrics: String?
}

private struct TavilyRequest: Encodable {
    let api_key: String
    let query: String
    let search_depth: String
    let max_results: Int
    let include_answer: Bool
}

private struct TavilyResponse: Decodable {
    struct Result: Decodable {
        let title: String?
        let url: String?
        let content: String?
    }
    let results: [Result]?
}

private struct WikiSearchResponse: Decodable {
    struct Query: Decodable {
        struct SearchItem: Decodable {
            let pageid: Int
            let title: String
        }
        let search: [SearchItem]?
    }
    let query: Query?
}

private struct WikiExtractResponse: Decodable {
    struct Query: Decodable {
        struct Page: Decodable {
            let pageid: Int?
            let title: String?
            let fullurl: String?
            let extract: String?
        }
        let pages: [String: Page]?
    }
    let query: Query?
}

private struct ITunesResponse: Decodable {
    struct Item: Decodable {
        let artistName: String?
        let collectionName: String?
        let trackName: String?
        let releaseDate: String?
        let primaryGenreName: String?
        let copyright: String?
        let trackCount: Int?
        let collectionViewUrl: String?
        let trackViewUrl: String?
    }
    let results: [Item]?
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
        let responseMimeType: String?
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

    @Published var tavilyApiKey: String {
        didSet {
            UserDefaults.standard.set(tavilyApiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.tavilyKeyStorageKey)
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
    @Published var searchNotice: String?

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasTavilyKey: Bool {
        !tavilyApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let apiKeyStorageKey = "gemini_api_key"
    private static let tavilyKeyStorageKey = "tavily_api_key"
    private static let trackCacheStorageKey = "musiclore_track_cache_v4"
    private static let albumCacheStorageKey = "musiclore_album_cache_v3"

    private let geminiModels = [
        "gemini-3.5-flash-lite",
        "gemini-flash-lite-latest",
        "gemini-3.1-flash-lite",
        "gemini-3-flash-preview",
        "gemini-3.8-flash"
    ]

    private var trackCache: [String: TrackAnalysis] = [:]
    private var albumCache: [String: AlbumAnalysis] = [:]
    private var lyricsCache: [String: String] = [:]
    private var activeTrackKey: String?
    private var activeAlbumKey: String?

    init() {
        self.apiKey = UserDefaults.standard.string(forKey: Self.apiKeyStorageKey) ?? ""
        self.tavilyApiKey = UserDefaults.standard.string(forKey: Self.tavilyKeyStorageKey) ?? ""
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
        searchNotice = nil
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
        searchNotice = nil

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

        let trimmedTavily = tavilyApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        async let lyricsTask = fetchLyrics(track: track)
        async let webTask = gatherWebResearch(
            track: track,
            tavilyQuery: "\"\(track.title)\" \"\(primaryArtist(from: track.artist))\" \(track.album) significato storia canzone intervista",
            wikiQuery: "\(primaryArtist(from: track.artist)) \(track.title) \(track.album)",
            tavilyKey: trimmedTavily,
            preferAlbumCatalog: false
        )

        let lyrics = await lyricsTask
        let web = await webTask

        if let lyrics {
            lyricsCache[key] = lyrics
        }
        searchNotice = web.notice

        let prompt = buildTrackPrompt(track: track, lyrics: lyrics, web: web)

        do {
            let rawJSON = try await callGeminiWithFallback(
                prompt: prompt,
                apiKey: trimmedKey,
                responseMimeType: "application/json",
                temperature: 0.25
            )
            let cleanedJSON = sanitizeJSONControlCharacters(extractJSONObject(from: rawJSON))
            guard let data = cleanedJSON.data(using: .utf8) else {
                throw ServiceError.invalidResponse("Risposta non leggibile dal modello.")
            }
            let decoded = try JSONDecoder().decode(TrackAnalysisPayload.self, from: data)
            let result = TrackAnalysis(
                storyAndReason: decoded.storyAndReason,
                context: decoded.context,
                lyricsExplanation: decoded.lyricsExplanation,
                curiosities: decoded.curiosities,
                lyricsFound: lyrics != nil,
                sources: web.sources,
                sourceSummary: web.summary
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
        searchNotice = nil

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

        let trimmedTavily = tavilyApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetAlbum = track.album.nilIfBlank ?? track.title
        let web = await gatherWebResearch(
            track: track,
            tavilyQuery: "\"\(targetAlbum)\" \"\(primaryArtist(from: track.artist))\" album storia intervista recensione data uscita",
            wikiQuery: "\(primaryArtist(from: track.artist)) \(targetAlbum) album",
            tavilyKey: trimmedTavily,
            preferAlbumCatalog: true
        )
        searchNotice = web.notice

        let prompt = buildAlbumPrompt(track: track, web: web)

        do {
            let rawJSON = try await callGeminiWithFallback(
                prompt: prompt,
                apiKey: trimmedKey,
                responseMimeType: "application/json",
                temperature: 0.25
            )
            let cleanedJSON = sanitizeJSONControlCharacters(extractJSONObject(from: rawJSON))
            guard let data = cleanedJSON.data(using: .utf8) else {
                throw ServiceError.invalidResponse("Risposta non leggibile dal modello.")
            }
            let decoded = try JSONDecoder().decode(AlbumAnalysisPayload.self, from: data)
            let result = AlbumAnalysis(
                albumTitle: decoded.albumTitle,
                releaseDate: decoded.releaseDate,
                originAndStory: decoded.originAndStory,
                contextAndGoal: decoded.contextAndGoal,
                titleMeaning: decoded.titleMeaning,
                curiosities: decoded.curiosities,
                sources: web.sources,
                sourceSummary: web.summary
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

    // MARK: - Domande specifiche (con ricerca web reale client-side)

    func askQuestion(_ rawQuestion: String, for track: CurrentTrack, focusCategory: String) async {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            qaErrorMessage = "Inserisci la tua Gemini API Key nelle Impostazioni (icona ingranaggio in alto a destra)."
            return
        }

        qaErrorMessage = nil
        searchNotice = nil
        isAnsweringQuestion = true
        defer { isAnsweringQuestion = false }

        let trimmedTavily = tavilyApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = focusCategory == "Album" ? (track.album.nilIfBlank ?? track.title) : track.title
        let web = await gatherWebResearch(
            track: track,
            tavilyQuery: "\(primaryArtist(from: track.artist)) \(subject) \(question)",
            wikiQuery: "\(primaryArtist(from: track.artist)) \(subject) \(question)",
            tavilyKey: trimmedTavily,
            preferAlbumCatalog: focusCategory == "Album"
        )
        searchNotice = web.notice

        let previousItems = Array((qaByTrack[track.id] ?? []).suffix(4))
        let lyrics = lyricsCache[track.id]
        let prompt = buildQuestionPrompt(
            question: question,
            track: track,
            focusCategory: focusCategory,
            lyrics: lyrics,
            web: web,
            history: previousItems
        )

        do {
            let rawAnswer = try await callGeminiWithFallback(
                prompt: prompt,
                apiKey: trimmedKey,
                responseMimeType: nil,
                temperature: 0.15
            )
            let cleanedAnswer = cleanPlainTextAnswer(rawAnswer)
            let item = QAItem(
                question: question,
                answer: cleanedAnswer,
                sources: web.sources,
                sourceSummary: web.summary
            )
            qaByTrack[track.id, default: []].append(item)
            qaErrorMessage = nil
        } catch {
            qaErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Motore di ricerca web diretto (Tavily + Wikipedia IT/EN + Catalogo iTunes)

    private func gatherWebResearch(
        track: CurrentTrack,
        tavilyQuery: String,
        wikiQuery: String,
        tavilyKey: String,
        preferAlbumCatalog: Bool
    ) async -> WebBundle {
        async let tavilyTask = fetchTavily(query: tavilyQuery, apiKey: tavilyKey)
        async let wikiITTask = fetchWikipedia(lang: "it", query: wikiQuery, limit: 2)
        async let wikiENTask = fetchWikipedia(lang: "en", query: wikiQuery, limit: 2)
        async let itunesTask = fetchITunes(track: track, preferAlbum: preferAlbumCatalog)

        let (tavilyResults, tavilyError) = await tavilyTask
        let wikiIT = await wikiITTask
        let wikiEN = await wikiENTask
        let itunes = await itunesTask

        var combined: [WebEvidence] = []
        var seenURLs = Set<String>()

        for item in tavilyResults + itunes + wikiIT + wikiEN {
            let urlKey = item.source.url.absoluteString
            if !seenURLs.contains(urlKey) {
                seenURLs.insert(urlKey)
                combined.append(item)
            }
        }

        let sources = combined.map(\.source)
        var providers: [String] = []
        if !tavilyResults.isEmpty { providers.append("Web") }
        if !wikiIT.isEmpty || !wikiEN.isEmpty { providers.append("Wikipedia") }
        if !itunes.isEmpty { providers.append("Apple Catalog") }

        let summary: String
        if providers.isEmpty {
            summary = "Nessuna fonte web trovata"
        } else {
            summary = "Fonti: " + providers.joined(separator: " + ")
        }

        return WebBundle(
            evidences: combined,
            sources: sources,
            summary: summary,
            notice: tavilyError
        )
    }

    private func fetchTavily(query: String, apiKey: String) async -> ([WebEvidence], String?) {
        guard !apiKey.isEmpty else { return ([], nil) }
        guard let url = URL(string: "https://api.tavily.com/search") else { return ([], nil) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 14
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body = TavilyRequest(
            api_key: apiKey,
            query: query,
            search_depth: "basic",
            max_results: 5,
            include_answer: false
        )

        do {
            request.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return ([], "Tavily: risposta non valida.")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return ([], "Chiave Tavily non valida nelle Impostazioni (uso Wikipedia + Catalogo).")
            }
            if http.statusCode == 429 || http.statusCode == 432 {
                return ([], "Quota mensile Tavily esaurita (uso Wikipedia + Catalogo).")
            }
            guard (200...299).contains(http.statusCode) else {
                return ([], "Tavily temporaneamente non disponibile (HTTP \(http.statusCode)).")
            }

            let decoded = try JSONDecoder().decode(TavilyResponse.self, from: data)
            let items: [WebEvidence] = (decoded.results ?? []).compactMap { result in
                guard let rawURL = result.url?.nilIfBlank,
                      let parsedURL = URL(string: rawURL),
                      let content = result.content?.nilIfBlank else {
                    return nil
                }
                let title = result.title?.nilIfBlank ?? parsedURL.host ?? "Fonte web"
                return WebEvidence(
                    source: VerifiedSource(title: title, url: parsedURL),
                    snippet: String(content.prefix(1200)),
                    provider: "Web"
                )
            }
            return (items, nil)
        } catch {
            return ([], "Ricerca Tavily non riuscita: uso Wikipedia + Catalogo.")
        }
    }

    private func fetchWikipedia(lang: String, query: String, limit: Int) async -> [WebEvidence] {
        var searchComp = URLComponents(string: "https://\(lang).wikipedia.org/w/api.php")
        searchComp?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "srlimit", value: "\(limit)"),
            URLQueryItem(name: "utf8", value: "1"),
            URLQueryItem(name: "format", value: "json")
        ]

        guard let searchURL = searchComp?.url else { return [] }
        var searchReq = URLRequest(url: searchURL)
        searchReq.timeoutInterval = 8
        searchReq.setValue("MusicLore/1.0 (iOS App)", forHTTPHeaderField: "User-Agent")

        do {
            let (searchData, searchResp) = try await URLSession.shared.data(for: searchReq)
            guard let http = searchResp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return []
            }
            let searchDecoded = try JSONDecoder().decode(WikiSearchResponse.self, from: searchData)
            let pageIDs = (searchDecoded.query?.search ?? []).map { String($0.pageid) }
            guard !pageIDs.isEmpty else { return [] }

            var extractComp = URLComponents(string: "https://\(lang).wikipedia.org/w/api.php")
            extractComp?.queryItems = [
                URLQueryItem(name: "action", value: "query"),
                URLQueryItem(name: "prop", value: "extracts|info"),
                URLQueryItem(name: "inprop", value: "url"),
                URLQueryItem(name: "explaintext", value: "1"),
                URLQueryItem(name: "exchars", value: "1800"),
                URLQueryItem(name: "pageids", value: pageIDs.joined(separator: "|")),
                URLQueryItem(name: "format", value: "json")
            ]

            guard let extractURL = extractComp?.url else { return [] }
            var extractReq = URLRequest(url: extractURL)
            extractReq.timeoutInterval = 8
            extractReq.setValue("MusicLore/1.0 (iOS App)", forHTTPHeaderField: "User-Agent")

            let (extractData, extractResp) = try await URLSession.shared.data(for: extractReq)
            guard let extractHTTP = extractResp as? HTTPURLResponse, (200...299).contains(extractHTTP.statusCode) else {
                return []
            }
            let extractDecoded = try JSONDecoder().decode(WikiExtractResponse.self, from: extractData)
            let pages = extractDecoded.query?.pages?.values ?? Dictionary<String, WikiExtractResponse.Query.Page>().values

            return pages.compactMap { page in
                guard let title = page.title?.nilIfBlank,
                      let rawURL = page.fullurl?.nilIfBlank,
                      let pageURL = URL(string: rawURL),
                      let extract = page.extract?.nilIfBlank else {
                    return nil
                }
                return WebEvidence(
                    source: VerifiedSource(title: "Wikipedia (\(lang.uppercased())): \(title)", url: pageURL),
                    snippet: String(extract.prefix(1600)),
                    provider: "Wikipedia \(lang.uppercased())"
                )
            }
        } catch {
            return []
        }
    }

    private func fetchITunes(track: CurrentTrack, preferAlbum: Bool) async -> [WebEvidence] {
        let term = preferAlbum
            ? "\(primaryArtist(from: track.artist)) \(track.album.nilIfBlank ?? track.title)"
            : "\(primaryArtist(from: track.artist)) \(track.title)"

        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: preferAlbum ? "album" : "song"),
            URLQueryItem(name: "country", value: "IT"),
            URLQueryItem(name: "limit", value: "2")
        ]

        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 7

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return []
            }
            let decoded = try JSONDecoder().decode(ITunesResponse.self, from: data)
            guard let item = decoded.results?.first else { return [] }

            let rawURL = (preferAlbum ? item.collectionViewUrl : (item.trackViewUrl ?? item.collectionViewUrl)) ?? ""
            guard let itemURL = URL(string: rawURL) else { return [] }

            var lines: [String] = []
            if let artist = item.artistName?.nilIfBlank { lines.append("Artista catalogo: \(artist)") }
            if let album = item.collectionName?.nilIfBlank { lines.append("Album ufficiale: \(album)") }
            if let song = item.trackName?.nilIfBlank { lines.append("Brano ufficiale: \(song)") }
            if let isoDate = item.releaseDate?.nilIfBlank {
                lines.append("Data di uscita ufficiale: \(formatItalianDate(from: isoDate))")
            }
            if let genre = item.primaryGenreName?.nilIfBlank { lines.append("Genere: \(genre)") }
            if let count = item.trackCount { lines.append("Numero tracce: \(count)") }
            if let copyright = item.copyright?.nilIfBlank { lines.append("Etichetta / Copyright: \(copyright)") }

            let label = item.collectionName?.nilIfBlank ?? item.trackName?.nilIfBlank ?? "Apple Music"
            return [
                WebEvidence(
                    source: VerifiedSource(title: "Catalogo Apple: \(label)", url: itemURL),
                    snippet: lines.joined(separator: "\n"),
                    provider: "Apple Catalog"
                )
            ]
        } catch {
            return []
        }
    }

    // MARK: - Prompt con controllo incrociato delle fonti

    private func buildTrackPrompt(track: CurrentTrack, lyrics: String?, web: WebBundle) -> String {
        let albumLine = track.album.isEmpty ? "Non specificato" : track.album
        let lyricsSection: String
        if let lyrics {
            lyricsSection = """
            Testo verificato del brano (da LRCLib):
            \"\"\"
            \(String(lyrics.prefix(5500)))
            \"\"\"
            """
        } else {
            lyricsSection = "Testo non trovato su LRCLib: non inventare versi o citazioni."
        }

        return """
        Sei un ricercatore musicale rigoroso. Analizza in italiano il seguente brano basandoti sulle fonti web fornite qui sotto, incrociandole ed eliminando eventuali pagine omonime non pertinenti.

        Titolo: \(track.title)
        Artista: \(track.artist)
        Album: \(albumLine)

        \(lyricsSection)

        FONTI WEB RECUPERATE ADESSO:
        \(web.promptContext)

        REGOLE FERREE:
        1. Dai massima priorità ai fatti confermati nelle fonti web sopra e nel testo verificato.
        2. Ignora eventuali risultati omonimi che non riguardano questo artista/brano.
        3. ZERO invenzioni: se un dettaglio (produttore, sample, intervista) non è confermato, non inventarlo.

        Restituisci ESCLUSIVAMENTE un oggetto JSON valido (nessun Markdown o asterischi) con queste 4 chiavi esatte:
        {
          "storyAndReason": "Come nasce il brano, perché è stato scritto, ispirazione e storia verificata della creazione.",
          "context": "Il contesto personale, artistico, culturale o storico in cui si inserisce il brano nella carriera dell'artista.",
          "lyricsExplanation": "Spiegazione chiara del significato del testo, dei temi principali, delle immagini e delle metafore chiave.",
          "curiosities": "Curiosità verificate, retroscena di registrazione, produttori, sample/campionamenti, collaborazioni o aneddoti reali."
        }
        """
    }

    private func buildAlbumPrompt(track: CurrentTrack, web: WebBundle) -> String {
        let albumInstruction: String
        if track.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            albumInstruction = "Album non indicato nei metadati: identifica dalle fonti l'album o EP di appartenenza del brano \"\(track.title)\" di \(track.artist)."
        } else {
            albumInstruction = "Album: \(track.album) (brano in ascolto: \(track.title))."
        }

        return """
        Sei un ricercatore musicale rigoroso. Racconta in italiano la storia completa dell'album basandoti sulle fonti web fornite qui sotto, ignorando eventuali pagine omonime non pertinenti.

        Artista: \(track.artist)
        \(albumInstruction)

        FONTI WEB RECUPERATE ADESSO:
        \(web.promptContext)

        REGOLE FERREE:
        1. Usa la data di uscita, i crediti e i fatti confermati dalle fonti web sopra (in particolare Catalogo Apple, Wikipedia e articoli).
        2. ZERO invenzioni: se un dettaglio non trova conferma, non inventarlo.

        Restituisci ESCLUSIVAMENTE un oggetto JSON valido (nessun Markdown o asterischi) con queste 6 chiavi esatte:
        {
          "albumTitle": "Titolo ufficiale dell'album o EP.",
          "releaseDate": "Data di uscita verificata in italiano (es. '29 ottobre 2021').",
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
        web: WebBundle,
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
            lyricsHint = "\nEstratto del testo verificato:\n\"\"\"\n\(String(lyrics.prefix(3500)))\n\"\"\"\n"
        } else {
            lyricsHint = ""
        }

        return """
        Sei un ricercatore musicale estremamente rigoroso. Rispondi in italiano alla domanda dell'utente incrociando le fonti web reali recuperate adesso qui sotto.

        Contesto attuale:
        - Categoria attiva: \(focusCategory)
        - Brano: \(track.title)
        - Artista: \(track.artist)
        - Album: \(albumLine)
        \(lyricsHint)\(historyBlock)
        FONTI WEB RECUPERATE ADESSO:
        \(web.promptContext)

        REGOLE OBBLIGATORIE:
        1. Controlla e incrocia le fonti web qui sopra (scartando eventuali pagine omonime non pertinenti).
        2. Conferma solo ciò che risulta verificabile. Se le fonti recuperate non confermano un dettaglio specifico, dillo chiaramente ("Nelle fonti trovate non risultano conferme ufficiali su questo punto") invece di inventare.
        3. Rispondi in testo semplice e diretto, senza asterischi Markdown tipo **grassetto**.

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
            URLQueryItem(name: "artist_name", value: primaryArtist(from: track.artist)),
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

    // MARK: - Chiamata Gemini (senza tool a quota bloccata)

    private func callGeminiWithFallback(
        prompt: String,
        apiKey: String,
        responseMimeType: String?,
        temperature: Double
    ) async throws -> String {
        var lastError: Error = ServiceError.invalidResponse("Nessun modello Gemini ha risposto.")

        for model in geminiModels {
            do {
                return try await callGemini(
                    model: model,
                    prompt: prompt,
                    apiKey: apiKey,
                    responseMimeType: responseMimeType,
                    temperature: temperature
                )
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

    private func callGemini(
        model: String,
        prompt: String,
        apiKey: String,
        responseMimeType: String?,
        temperature: Double
    ) async throws -> String {
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        guard let url = components?.url else {
            throw ServiceError.fatal("URL API non valido.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = GeminiRequest(
            contents: [.init(parts: [.init(text: prompt)])],
            generationConfig: .init(temperature: temperature, responseMimeType: responseMimeType)
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
        guard let text = decoded.candidates?.first?.content?.parts?.compactMap(\.text).joined().nilIfBlank else {
            throw ServiceError.retryable("[\(model)] Risposta vuota.")
        }
        return text
    }

    // MARK: - Utilità

    private func primaryArtist(from artist: String) -> String {
        let separators = [" & ", ",", " feat.", " ft.", " featuring "]
        var cleaned = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        for sep in separators {
            if let range = cleaned.range(of: sep, options: .caseInsensitive) {
                cleaned = String(cleaned[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return cleaned.isEmpty ? artist : cleaned
    }

    private func formatItalianDate(from isoString: String) -> String {
        let iso = ISO8601DateFormatter()
        guard let date = iso.date(from: isoString) else { return isoString }
        let df = DateFormatter()
        df.locale = Locale(identifier: "it_IT")
        df.dateStyle = .long
        df.timeStyle = .none
        return df.string(from: date)
    }

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