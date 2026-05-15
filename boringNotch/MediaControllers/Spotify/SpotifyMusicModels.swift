//
//  SpotifyMusicModels.swift
//  boringNotch
//
//  Spotify 控制层内部用的 PlayerState DTO（与全局 PlaybackState 解耦）。
//

import Foundation

struct SpotifyPlayerState {
    var isPlaying: Bool = false
    var trackName: String = "Unknown"
    var artist: String = "Unknown"
    var album: String = "Unknown"
    var position: Double = 0
    var duration: Double = 0
    var trackID: String = ""
    var shuffle: Bool = false
    var repeatMode: RepeatMode = .off
    var volume: Int = 50
    var artworkURL: String = ""
    var isLiked: Bool = false
}
