//
//  SpotifyAppleScriptProvider.swift
//  boringNotch
//
//  没有 Web API 权限时的兜底实现。AppleScript 只支持 bool repeating，三态降级为开/关。
//

import Foundation

final class SpotifyAppleScriptProvider: SpotifyProvider {
    let supportsFavorite: Bool = false

    func getPlayerState() async -> SpotifyPlayerState {
        let script = """
        tell application "Spotify"
            set isRunning to true
            try
                set playerState to player state is playing
                set currentTrackName to name of current track
                set currentTrackArtist to artist of current track
                set currentTrackAlbum to album of current track
                set trackPosition to player position
                set trackDuration to duration of current track
                set shuffleState to shuffling
                set repeatState to repeating
                set currentVolume to sound volume
                set artworkURL to artwork url of current track
                return {playerState, currentTrackName, currentTrackArtist, currentTrackAlbum, trackPosition, trackDuration, shuffleState, repeatState, currentVolume, artworkURL}
            on error
                return {false, "Unknown", "Unknown", "Unknown", 0, 0, false, false, 50, ""}
            end try
        end tell
        """

        guard let result = try? await AppleScriptHelper.execute(script) else {
            return SpotifyPlayerState()
        }

        let repeating = result.atIndex(8)?.booleanValue ?? false

        return SpotifyPlayerState(
            isPlaying: result.atIndex(1)?.booleanValue ?? false,
            trackName: result.atIndex(2)?.stringValue ?? "Unknown",
            artist: result.atIndex(3)?.stringValue ?? "Unknown",
            album: result.atIndex(4)?.stringValue ?? "Unknown",
            position: result.atIndex(5)?.doubleValue ?? 0,
            duration: (result.atIndex(6)?.doubleValue ?? 0) / 1000,
            trackID: "",
            shuffle: result.atIndex(7)?.booleanValue ?? false,
            repeatMode: repeating ? .all : .off,
            volume: Int(result.atIndex(9)?.int32Value ?? 50),
            artworkURL: result.atIndex(10)?.stringValue ?? "",
            isLiked: false
        )
    }

    func play() async { await executeCommand("play") }
    func pause() async { await executeCommand("pause") }
    func togglePlay() async { await executeCommand("playpause") }
    func nextTrack() async { await executeCommand("next track") }
    func previousTrack() async { await executeCommand("previous track") }
    func seek(to time: Double) async { await executeCommand("set player position to \(time)") }

    func setVolume(_ volume: Int) async {
        await executeCommand("set sound volume to \(max(0, min(100, volume)))")
    }

    func setShuffle(_ enabled: Bool) async -> Bool {
        await executeCommand("set shuffling to \(enabled)")
        return true
    }

    func setRepeatMode(_ mode: RepeatMode) async -> Bool {
        // AppleScript 只支持 bool。.one/.all 都映射为 true（开启 repeat）。
        await executeCommand("set repeating to \(mode == .off ? "false" : "true")")
        return true
    }

    func isTrackLiked(id: String) async -> Bool { false }

    func setLiked(_ liked: Bool, id: String) async {
        // Spotify 的 AppleScript 字典里没有 unlike，所以取消喜欢这条直接忽略。
        guard liked else { return }
        await executeCommand("like track")
    }

    private func executeCommand(_ command: String) async {
        let script = "tell application \"Spotify\" to \(command)"
        try? await AppleScriptHelper.executeVoid(script)
    }
}
