//
//  SpotifyMusicProvider.swift
//  boringNotch
//

protocol SpotifyProvider {
    var supportsFavorite: Bool { get }

    func getPlayerState() async -> SpotifyPlayerState
    func play() async
    func pause() async
    func togglePlay() async
    func nextTrack() async
    func previousTrack() async
    func seek(to time: Double) async
    func setVolume(_ volume: Int) async
    func setShuffle(_ enabled: Bool) async
    // 三态 repeat：.off / .all / .one；AppleScript 只能 bool 化（.one 实际落到 .all）
    func setRepeatMode(_ mode: RepeatMode) async
    func isTrackLiked(id: String) async -> Bool
    func setLiked(_ liked: Bool, id: String) async
}
