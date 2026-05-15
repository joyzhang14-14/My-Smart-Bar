//
//  SpotifyMusicProvider.swift
//  boringNotch
//

protocol SpotifyProvider: AnyObject {
    var supportsFavorite: Bool { get }

    func getPlayerState() async -> SpotifyPlayerState
    func play() async
    func pause() async
    func togglePlay() async
    func nextTrack() async
    func previousTrack() async
    func seek(to time: Double) async
    func setVolume(_ volume: Int) async
    // 写命令返回是否生效：Web API 在没有 active device 时返 404，需要让上层兜底
    func setShuffle(_ enabled: Bool) async -> Bool
    // 三态 repeat：.off / .all (Spotify context) / .one (Spotify track)
    func setRepeatMode(_ mode: RepeatMode) async -> Bool
    func isTrackLiked(id: String) async -> Bool
    func setLiked(_ liked: Bool, id: String) async
}
