import Foundation
import MediaPlayer
import UIKit

struct CurrentTrack: Equatable {
    let title: String
    let artist: String
    let album: String
    let artwork: UIImage?
}

@MainActor
final class NowPlayingManager: ObservableObject {
    @Published var currentTrack: CurrentTrack?
    @Published var authorizationDenied = false

    private let player = MPMusicPlayerController.systemMusicPlayer

    init() {
        NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: player,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNowPlaying()
            }
        }
        player.beginGeneratingPlaybackNotifications()
    }

    func requestPermissionAndRefresh() {
        MPMediaLibrary.requestAuthorization { [weak self] status in
            Task { @MainActor in
                if status == .authorized {
                    self?.authorizationDenied = false
                    self?.refreshNowPlaying()
                } else {
                    self?.authorizationDenied = true
                }
            }
        }
    }

    func refreshNowPlaying() {
        guard let item = player.nowPlayingItem,
              let title = item.title,
              let artist = item.artist else {
            currentTrack = nil
            return
        }

        let artwork = item.artwork?.image(at: CGSize(width: 600, height: 600))
        currentTrack = CurrentTrack(
            title: title,
            artist: artist,
            album: item.albumTitle ?? "",
            artwork: artwork
        )
    }
}