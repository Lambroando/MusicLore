import MediaPlayer
import SwiftUI
import UIKit

private enum AnalysisCategory: String, CaseIterable, Identifiable {
    case song = "Canzone"
    case album = "Album"

    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var nowPlaying = NowPlayingManager()
    @StateObject private var analysisService = AnalysisService()

    @State private var selectedCategory: AnalysisCategory = .song
    @State private var showSettings = false
    @State private var showManualSearch = false
    @State private var questionText = ""
    @FocusState private var isQuestionFocused: Bool

    private var activeTaskID: String {
        "\(nowPlaying.currentTrack?.id ?? "none")|\(selectedCategory.rawValue)"
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 18) {
                    if let track = nowPlaying.currentTrack {
                        trackHeader(track)
                        categoryPicker
                        if selectedCategory == .song {
                            songAnalysisContent(track)
                        } else {
                            albumAnalysisContent(track)
                        }
                        qaSection(track)
                    } else {
                        emptyStateView
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                backgroundView
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showManualSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.headline)
                    }
                }

                ToolbarItem(placement: .principal) {
                    Text("MusicLore")
                        .font(.headline.bold())
                        .foregroundStyle(.white)
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        nowPlaying.refreshFromAppleMusic(clearManual: true)
                        if let track = nowPlaying.currentTrack {
                            Task {
                                switch selectedCategory {
                                case .song:
                                    await analysisService.analyze(track: track, forceRefresh: true)
                                case .album:
                                    await analysisService.analyzeAlbum(track: track, forceRefresh: true)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.headline)
                    }

                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                guard analysisService.hasAPIKey, let track = nowPlaying.currentTrack else { return }
                Task {
                    switch selectedCategory {
                    case .song:
                        if analysisService.analysis == nil {
                            await analysisService.analyze(track: track)
                        }
                    case .album:
                        if analysisService.albumAnalysis == nil {
                            await analysisService.analyzeAlbum(track: track)
                        }
                    }
                }
            }) {
                SettingsSheet(analysisService: analysisService)
            }
            .sheet(isPresented: $showManualSearch) {
                ManualSearchSheet { title, artist, album in
                    nowPlaying.setManualTrack(title: title, artist: artist, album: album)
                }
            }
            .onAppear {
                nowPlaying.requestPermissionAndRefresh()
            }
            .task(id: activeTaskID) {
                guard let track = nowPlaying.currentTrack else { return }
                analysisService.qaErrorMessage = nil
                switch selectedCategory {
                case .song:
                    await analysisService.analyze(track: track)
                case .album:
                    await analysisService.analyzeAlbum(track: track)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Selettore Canzone / Album

    private var categoryPicker: some View {
        Picker("Categoria", selection: $selectedCategory) {
            ForEach(AnalysisCategory.allCases) { category in
                Text(category.rawValue).tag(category)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Sfondo vincolato allo schermo

    private var backgroundView: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if let artwork = nowPlaying.currentTrack?.artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: 45)
                        .opacity(0.28)
                }

                LinearGradient(
                    colors: [Color.black.opacity(0.35), Color.black.opacity(0.88)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }

    // MARK: - Intestazione brano

    private func trackHeader(_ track: CurrentTrack) -> some View {
        VStack(spacing: 10) {
            if let artwork = track.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 210, height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                    Image(systemName: "music.note")
                        .font(.system(size: 56))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(width: 170, height: 170)
            }

            Text(track.title)
                .font(.title2.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)

            Text(track.artist)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)

            if !track.album.isEmpty {
                Text(track.album)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }

            if nowPlaying.isManualTrack {
                Button {
                    nowPlaying.refreshFromAppleMusic(clearManual: true)
                } label: {
                    Label("Torna ad Apple Music", systemImage: "music.note.list")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Contenuto analisi Canzone

    @ViewBuilder
    private func songAnalysisContent(_ track: CurrentTrack) -> some View {
        if analysisService.isLoading {
            loadingCard(message: "Ricerca web e analisi del brano in corso...")
        } else if let error = analysisService.errorMessage {
            errorCard(message: error) {
                Task {
                    await analysisService.analyze(track: track, forceRefresh: true)
                }
            }
        } else if let analysis = analysisService.analysis {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    if analysis.webVerified {
                        Label("Verificato online", systemImage: "checkmark.shield.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }

                    if analysis.lyricsFound {
                        Label("Testo OK", systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.mint)
                    }

                    if analysisService.isFromCache {
                        Label("In cache", systemImage: "bolt.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                }
                .frame(maxWidth: .infinity)

                AnalysisCard(title: "Storia e motivo", text: analysis.storyAndReason)
                AnalysisCard(title: "Contesto", text: analysis.context)
                AnalysisCard(title: "Spiegazione del testo", text: analysis.lyricsExplanation)
                AnalysisCard(title: "Curiosità e retroscena", text: analysis.curiosities)

                if !analysis.sources.isEmpty {
                    SourcesCard(sources: analysis.sources)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Contenuto analisi Album

    @ViewBuilder
    private func albumAnalysisContent(_ track: CurrentTrack) -> some View {
        if analysisService.isLoadingAlbum {
            loadingCard(message: "Ricerca web e analisi dell'album in corso...")
        } else if let error = analysisService.albumErrorMessage {
            errorCard(message: error) {
                Task {
                    await analysisService.analyzeAlbum(track: track, forceRefresh: true)
                }
            }
        } else if let album = analysisService.albumAnalysis {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    if album.webVerified {
                        Label("Verificato online", systemImage: "checkmark.shield.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }

                    if analysisService.isAlbumFromCache {
                        Label("Album in cache", systemImage: "bolt.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                }
                .frame(maxWidth: .infinity)

                AlbumInfoBanner(title: album.albumTitle, releaseDate: album.releaseDate)
                AnalysisCard(title: "Come nasce l'album", text: album.originAndStory)
                AnalysisCard(title: "Contesto e obiettivo", text: album.contextAndGoal)
                AnalysisCard(title: "Significato del titolo", text: album.titleMeaning)
                AnalysisCard(title: "Curiosità e retroscena", text: album.curiosities)

                if !album.sources.isEmpty {
                    SourcesCard(sources: album.sources)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Sezione domande specifiche (sempre con ricerca web)

    private func qaSection(_ track: CurrentTrack) -> some View {
        let items = analysisService.qaItems(for: track)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Chiedi qualcosa", systemImage: "bubble.left.and.text.bubble.right.fill")
                        .font(.headline.bold())
                        .foregroundStyle(.white)

                    Text("Ricerca Google sempre attiva con conferma delle fonti.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !items.isEmpty {
                    Button("Pulisci") {
                        analysisService.clearQA(for: track)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                }
            }

            if !items.isEmpty {
                VStack(spacing: 12) {
                    ForEach(items) { item in
                        QACardView(item: item)
                    }
                }
            }

            if analysisService.isAnsweringQuestion {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text("Cerco su Google e verifico le fonti...")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if let qaError = analysisService.qaErrorMessage {
                Text(qaError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Es. Chi ha prodotto il beat? Che sample usa?", text: $questionText, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .focused($isQuestionFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button {
                    submitQuestion(for: track)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(canSendQuestion ? .blue : .white.opacity(0.25))
                }
                .disabled(!canSendQuestion)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.top, 6)
    }

    private var canSendQuestion: Bool {
        !questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !analysisService.isAnsweringQuestion
    }

    private func submitQuestion(for track: CurrentTrack) {
        let prompt = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        questionText = ""
        isQuestionFocused = false
        let focus = selectedCategory.rawValue

        Task {
            await analysisService.askQuestion(prompt, for: track, focusCategory: focus)
        }
    }

    // MARK: - Componenti comuni stato caricamento / errore

    private func loadingCard(message: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func errorCard(message: String, onRetry: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)

            Button("Riprova", action: onRetry)
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.15))
                .foregroundStyle(.blue)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Stato vuoto

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.house.fill")
                .font(.system(size: 52))
                .foregroundStyle(.white.opacity(0.6))

            Text("Nessun brano in riproduzione")
                .font(.title3.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text("Avvia una canzone su Apple Music e premi Aggiorna, oppure cerca un brano manualmente.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if nowPlaying.authorizationStatus == .denied || nowPlaying.authorizationStatus == .restricted {
                Button("Apri Impostazioni per Apple Music") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 12) {
                Button("Aggiorna") {
                    nowPlaying.requestPermissionAndRefresh()
                }
                .buttonStyle(.borderedProminent)

                Button("Cerca brano") {
                    showManualSearch = true
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .padding(.top, 40)
    }
}

// MARK: - Lista fonti verificate

private struct SourcesListView: View {
    let sources: [VerifiedSource]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Fonti consultate:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.65))

            ForEach(sources.prefix(6)) { source in
                Link(destination: source.url) {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.caption2)
                        Text(source.title)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                    }
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }
}

private struct SourcesCard: View {
    let sources: [VerifiedSource]

    var body: some View {
        SourcesListView(sources: sources)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Card singola domanda/risposta

private struct QACardView: View {
    let item: QAItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.question)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.24), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(item.answer)
                .font(.body)
                .foregroundStyle(.white.opacity(0.92))
                .lineSpacing(4)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Label("Verificato online", systemImage: "checkmark.shield.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)

            if !item.sources.isEmpty {
                SourcesListView(sources: item.sources)
                    .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Banner scheda album

private struct AlbumInfoBanner: View {
    let title: String
    let releaseDate: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "opticaldisc.fill")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.85))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Label("Uscita: \(releaseDate)", systemImage: "calendar")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Card testo

private struct AnalysisCard: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(text)
                .font(.body)
                .foregroundStyle(.white.opacity(0.9))
                .lineSpacing(4)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Impostazioni

private struct SettingsSheet: View {
    @ObservedObject var analysisService: AnalysisService
    @Environment(\.dismiss) private var dismiss
    @State private var cacheCleared = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Incolla la tua Gemini API Key", text: $analysisService.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Google AI Studio API Key")
                } footer: {
                    Text("La chiave viene salvata solo in locale sul tuo iPhone.")
                }

                Section("Cache locale") {
                    Button(role: .destructive) {
                        analysisService.clearCache()
                        cacheCleared = true
                    } label: {
                        Text("Svuota cache di brani e album analizzati")
                    }

                    if cacheCleared {
                        Text("Cache svuotata.")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fine") {
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Ricerca manuale

private struct ManualSearchSheet: View {
    let onSelect: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Dettagli brano") {
                    TextField("Titolo del brano", text: $title)
                    TextField("Artista", text: $artist)
                    TextField("Album (opzionale)", text: $album)
                }

                Section {
                    Button("Analizza brano") {
                        onSelect(title, artist, album)
                        dismiss()
                    }
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle("Cerca brano")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annulla") {
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}