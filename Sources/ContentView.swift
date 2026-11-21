import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var nowPlaying = NowPlayingManager()
    @StateObject private var analysisService = AnalysisService()

    @State private var manualTrack: CurrentTrack?
    @State private var showSettings = false
    @State private var showManualSearch = false
    @State private var searchTitle = ""
    @State private var searchArtist = ""
    @State private var searchAlbum = ""

    private var displayedTrack: CurrentTrack? {
        manualTrack ?? nowPlaying.currentTrack
    }

    private var displayedTrackKey: String {
        guard let track = displayedTrack else { return "" }
        return "\(track.artist)|\(track.title)"
    }

    private var nowPlayingKey: String {
        guard let track = nowPlaying.currentTrack else { return "" }
        return "\(track.artist)|\(track.title)"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundLayer

                ScrollView {
                    VStack(spacing: 20) {
                        if nowPlaying.authorizationDenied && manualTrack == nil {
                            permissionDeniedView
                        } else if let track = displayedTrack {
                            trackHeader(track)
                            analysisSection(for: track)
                        } else {
                            emptyStateView
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("MusicLore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showManualSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        manualTrack = nil
                        nowPlaying.refreshNowPlaying()
                        if let track = nowPlaying.currentTrack {
                            Task { await analysisService.analyze(track: track, forceRefresh: false) }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }

                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: analysisService.hasAPIKey ? "gearshape" : "gearshape.fill")
                            .foregroundStyle(analysisService.hasAPIKey ? Color.primary : Color.orange)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                settingsSheet
            }
            .sheet(isPresented: $showManualSearch) {
                manualSearchSheet
            }
            .onAppear {
                nowPlaying.requestPermissionAndRefresh()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    nowPlaying.refreshNowPlaying()
                }
            }
            .onChange(of: nowPlayingKey) { _, newValue in
                if !newValue.isEmpty {
                    manualTrack = nil
                }
            }
            .onChange(of: displayedTrackKey) { _, newValue in
                guard !newValue.isEmpty, let track = displayedTrack else { return }
                Task {
                    await analysisService.analyze(track: track, forceRefresh: false)
                }
            }
        }
    }

    // MARK: - Sfondo dinamico dalla copertina

    @ViewBuilder
    private var backgroundLayer: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let artwork = displayedTrack?.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 55)
                    .opacity(0.42)
                    .ignoresSafeArea()
            }

            LinearGradient(
                colors: [Color.black.opacity(0.35), Color.black.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Intestazione brano

    private func trackHeader(_ track: CurrentTrack) -> some View {
        VStack(spacing: 14) {
            if let artwork = track.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 210, height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.55), radius: 22, y: 12)
            } else {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(width: 180, height: 180)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 54))
                            .foregroundStyle(.secondary)
                    }
            }

            VStack(spacing: 5) {
                Text(track.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text(track.artist)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if !track.album.isEmpty {
                    Text(track.album)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }

            if manualTrack != nil {
                Button("Torna al brano su Apple Music") {
                    manualTrack = nil
                    nowPlaying.refreshNowPlaying()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Schede di analisi

    @ViewBuilder
    private func analysisSection(for track: CurrentTrack) -> some View {
        if analysisService.isLoading {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("Cerco testo e storia del brano...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else if let error = analysisService.errorMessage {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)

                Text(error)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    if !analysisService.hasAPIKey {
                        Button("Inserisci chiave API") {
                            showSettings = true
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button("Riprova") {
                        Task { await analysisService.analyze(track: track, forceRefresh: true) }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else if let result = analysisService.analysis {
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    Label(
                        result.lyricsFound ? "Testo verificato" : "Analisi da archivio AI",
                        systemImage: result.lyricsFound ? "checkmark.seal.fill" : "sparkles"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(result.lyricsFound ? .green : .secondary)

                    if analysisService.isFromCache {
                        Text("• Salvata in cache")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                analysisCard(
                    title: "Storia e motivo",
                    icon: "book.pages.fill",
                    accent: .pink,
                    content: result.storyAndReason
                )

                analysisCard(
                    title: "Contesto",
                    icon: "clock.arrow.circlepath",
                    accent: .cyan,
                    content: result.context
                )

                analysisCard(
                    title: "Spiegazione del testo",
                    icon: "quote.bubble.fill",
                    accent: .purple,
                    content: result.lyricsExplanation
                )

                Button {
                    Task { await analysisService.analyze(track: track, forceRefresh: true) }
                } label: {
                    Label("Rigenera analisi", systemImage: "sparkles")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
        }
    }

    private func analysisCard(title: String, icon: String, accent: Color, content: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(accent)
                Text(title)
                    .font(.headline)
            }

            Text(content)
                .font(.body)
                .lineSpacing(5)
                .foregroundStyle(.primary.opacity(0.92))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Stati vuoti / permessi

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 52))
                .foregroundStyle(.pink)

            Text("Nessun brano in riproduzione")
                .font(.title3.bold())

            Text("Fai partire una canzone su Apple Music e torna qui, oppure cercane una manualmente.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Aggiorna") {
                    nowPlaying.refreshNowPlaying()
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)

                Button("Cerca brano") {
                    showManualSearch = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(28)
        .padding(.top, 50)
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 50))
                .foregroundStyle(.orange)

            Text("Accesso ad Apple Music negato")
                .font(.title3.bold())

            Text("Per leggere automaticamente il brano in ascolto, attiva \"Contenuti multimediali e Apple Music\" nelle Impostazioni di iOS.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Apri Impostazioni iOS") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .padding(.top, 50)
    }

    // MARK: - Impostazioni & Ricerca Manuale

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Incolla la Gemini API Key", text: $analysisService.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Google AI Studio (Gemini API)")
                } footer: {
                    Text("La chiave resta salvata solo sul tuo iPhone. Puoi crearla gratis su aistudio.google.com.")
                }

                Section("Archivio locale") {
                    Button("Svuota cache delle analisi", role: .destructive) {
                        analysisService.clearCache()
                    }
                }
            }
            .navigationTitle("Impostazioni")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fine") {
                        showSettings = false
                        if let track = displayedTrack, analysisService.hasAPIKey, analysisService.analysis == nil {
                            Task { await analysisService.analyze(track: track, forceRefresh: false) }
                        }
                    }
                }
            }
        }
    }

    private var manualSearchSheet: some View {
        NavigationStack {
            Form {
                Section("Dettagli brano") {
                    TextField("Titolo canzone", text: $searchTitle)
                    TextField("Artista", text: $searchArtist)
                    TextField("Album (opzionale)", text: $searchAlbum)
                }
            }
            .navigationTitle("Cerca manualmente")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annulla") {
                        showManualSearch = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Analizza") {
                        let title = searchTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        let artist = searchArtist.trimmingCharacters(in: .whitespacesAndNewlines)
                        let album = searchAlbum.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !title.isEmpty, !artist.isEmpty else { return }
                        manualTrack = CurrentTrack(title: title, artist: artist, album: album, artwork: nil)
                        showManualSearch = false
                    }
                    .disabled(
                        searchTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        searchArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
    }
}