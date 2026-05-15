//
//  SpotifyController.swift
//  boringNotch
//
//  Spotify 控制器：基于 Spotify 桌面 App 的 AppleScript 字典完成所有读写。
//  Web API 集成已移除（限流麻烦、且单曲循环也无法可靠生效）。
//  三态 repeat 在 UI 上以"用户意图"形式保留——AppleScript bool 只能表达 off/on，
//  .one 写到 Spotify 端实际等同 .all。
//

import Foundation
import Combine
import SwiftUI

final class SpotifyController: MediaControllerProtocol {

    @Published private var playbackState = PlaybackState(bundleIdentifier: "com.spotify.client")

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool { true }
    var supportsFavorite: Bool { true }  // 走 AppleScript like track（add-only）

    private let provider: SpotifyProvider

    private var notificationTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var artworkFetchTask: Task<Void, Never>?
    private var lastArtworkURL: String?
    private let commandUpdateDelay: Duration = .milliseconds(25)
    private let pollingInterval: Duration = .seconds(1)

    @MainActor
    convenience init() {
        self.init(provider: SpotifyAppleScriptProvider())
    }

    init(provider: SpotifyProvider) {
        self.provider = provider

        setupPlaybackStateChangeObserver()
        startPolling()

        Task { [weak self] in
            guard let self, self.isActive() else { return }
            await self.updatePlaybackInfo()
        }
    }

    deinit {
        notificationTask?.cancel()
        pollingTask?.cancel()
        artworkFetchTask?.cancel()
    }

    // MARK: - MediaControllerProtocol

    func setFavorite(_ favorite: Bool) async {
        // Spotify AppleScript 字典只有 like track（add），没有 unlike → liked=false 是 no-op
        await provider.setLiked(favorite, id: "")
    }

    func play() async { await provider.play() }
    func pause() async { await provider.pause() }
    func togglePlay() async { await provider.togglePlay() }
    func nextTrack() async { await provider.nextTrack() }

    func previousTrack() async {
        await provider.previousTrack()
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }

    func seek(to time: Double) async {
        await provider.seek(to: time)
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }

    func toggleShuffle() async {
        let target = !playbackState.isShuffled
        await provider.setShuffle(target)
        playbackState.isShuffled = target
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }

    // UI 三态 cycle：off → all → one → off
    // AppleScript bool 只能 off/on，.one 在 Spotify 端实际落到 .all；
    // cached repeatMode 当作"用户意图"立即推进，AppleScript 读不会覆盖（见 updatePlaybackInfo）
    func toggleRepeat() async {
        let next: RepeatMode
        switch playbackState.repeatMode {
        case .off: next = .all
        case .all: next = .one
        case .one: next = .off
        }
        await provider.setRepeatMode(next)
        playbackState.repeatMode = next
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }

    func setVolume(_ level: Double) async {
        let clamped = max(0.0, min(1.0, level))
        await provider.setVolume(Int(clamped * 100))
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }

    nonisolated func isActive() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" }
    }

    func updatePlaybackInfo() async {
        let playerState = await provider.getPlayerState()

        var state = PlaybackState(
            bundleIdentifier: "com.spotify.client",
            isPlaying: playerState.isPlaying,
            title: playerState.trackName,
            artist: playerState.artist,
            album: playerState.album,
            currentTime: playerState.position,
            duration: playerState.duration,
            playbackRate: 1,
            isShuffled: playerState.shuffle,
            // AppleScript bool 读会把 .one 退成 .all → 保留 cached 的用户意图
            repeatMode: playbackState.repeatMode,
            lastUpdated: Date(),
            artwork: nil,
            volume: Double(playerState.volume) / 100.0,
            isFavorite: playerState.isLiked
        )

        if playerState.artworkURL == lastArtworkURL, let existingArtwork = playbackState.artwork {
            state.artwork = existingArtwork
        }

        playbackState = state

        guard !playerState.artworkURL.isEmpty,
              let url = URL(string: playerState.artworkURL),
              playerState.artworkURL != lastArtworkURL || state.artwork == nil else {
            return
        }

        artworkFetchTask?.cancel()

        let currentState = state
        let artworkURL = playerState.artworkURL

        artworkFetchTask = Task { [weak self] in
            do {
                let data = try await ImageService.shared.fetchImageData(from: url)
                guard let self else { return }
                var updatedState = currentState
                updatedState.artwork = data
                self.playbackState = updatedState
                self.lastArtworkURL = artworkURL
                self.artworkFetchTask = nil
            } catch {
                guard let self else { return }
                self.artworkFetchTask = nil
            }
        }
    }

    // MARK: - Private
    private func setupPlaybackStateChangeObserver() {
        notificationTask = Task { [weak self] in
            let notifications = DistributedNotificationCenter.default().notifications(
                named: NSNotification.Name("com.spotify.client.PlaybackStateChanged")
            )
            for await _ in notifications {
                guard let self else { return }
                await self.updatePlaybackInfo()
            }
        }
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: self.pollingInterval)
                guard self.isActive() else { continue }
                await self.updatePlaybackInfo()
            }
        }
    }
}
