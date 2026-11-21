private func requestGeminiAnalysis(track: CurrentTrack, lyrics: String?, apiKey: String) async throws -> TrackAnalysis {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw AnalysisError.invalidURL
        }

        let lyricsSection: String
        if let lyrics {
            lyricsSection = """
            Ecco il testo ufficiale del brano (usalo come riferimento principale):
            ---
            \(lyrics)
            ---
            """
        } else {
            lyricsSection = """
            Il testo integrale non è disponibile: basati solo sulla tua conoscenza accertata del brano senza inventare versi.
            """
        }

        let prompt = """
        Sei un critico musicale. Analizza in italiano, in modo chiaro, concreto e sintetico, il seguente brano:
        - Titolo: \(track.title)
        - Artista: \(track.artist)
        - Album: \(track.album.isEmpty ? "Non specificato" : track.album)

        \(lyricsSection)

        Restituisci un JSON con esattamente questi tre campi (massimo 120 parole per campo, usa \\n\\n tra i paragrafi):
        1. "storyAndReason": storia del brano, com'è nato e motivo per cui è stato scritto.
        2. "context": contesto storico, culturale e della carriera dell'artista o dell'album.
        3. "lyricsExplanation": spiegazione del significato del testo, temi principali e metafore chiave.
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
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 120
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
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
