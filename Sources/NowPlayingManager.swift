import Combine
import Foundation
import MediaPlayer
import UIKit

struct CurrentTrack: Equatable, Identifiable {
    let title: String
    let artist: String
    let album: String
    let artwork: UIImage?

    var id: String {
        "\(artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))|\(title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    static func == (lhs: CurrentTrack, rhs: CurrentTrack) -> Bool {
        lhs.id == rhs.id && lhs.album == rhs.album
    }
}

@MainActor
final class NowPlayingManager: ObservableObject {
    @Published var currentTrack: CurrentTrack?
    @Published var isManualTrack = false
    @Published var authorizationStatus: MPMediaLibraryAuthorizationStatus = MPMediaLibrary.authorizationStatus()

    private let player = MPMusicPlayerController.systemMusicPlayer
    private var cancellables = Set<AnyCancellable>()

    init() {
        player.beginGeneratingPlaybackNotifications()

        NotificationCenter.default.publisher(for: .MPMusicPlayerControllerNowPlayingItemDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshFromAppleMusic(clearManual: false)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .MPMusicPlayerControllerPlaybackStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshFromAppleMusic(clearManual: false)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshFromAppleMusic(clearManual: false)
            }
            .store(in: &cancellables)
    }

    func requestPermissionAndRefresh() {
        let current = MPMediaLibrary.authorizationStatus()
        authorizationStatus = current

        if current == .notDetermined {
            MPMediaLibrary.requestAuthorization { status in
                Task { @MainActor [weak self] in
                    self?.authorizationStatus = status
                    if status == .authorized {
                        self?.refreshFromAppleMusic(clearManual: false)
                    }
                }
            }
        } else if current == .authorized {
            refreshFromAppleMusic(clearManual: false)
        }
    }

    func refreshFromAppleMusic(clearManual: Bool = false) {
        if !clearManual && isManualTrack {
            return
        }

        guard let item = player.nowPlayingItem,
              let rawTitle = item.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTitle.isEmpty else {
            return
        }

        let artist = item.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = item.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artwork = item.artwork?.image(at: CGSize(width: 600, height: 600))

        isManualTrack = false
        currentTrack = CurrentTrack(
            title: rawTitle,
            artist: (artist?.isEmpty == false ? artist! : "Artista sconosciuto"),
            album: album,
            artwork: artwork
        )
    }

    func setManualTrack(title: String, artist: String, album: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanArtist.isEmpty else { return }

        isManualTrack = true
        currentTrack = CurrentTrack(
            title: cleanTitle,
            artist: cleanArtist,
            album: cleanAlbum,
            artwork: nil
        )
    }
}