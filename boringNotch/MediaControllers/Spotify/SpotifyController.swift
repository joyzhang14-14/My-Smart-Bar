//
//  SpotifyController.swift
//  boringNotch
//
//  Spotify 控制器：协调 WebAPI 与 AppleScript 两套 provider。
//  有有效 access token 时走 Web API（支持 Like + 三态 Repeat），
//  否则降级到 AppleScript（不支持 Like、Repeat 退化为 bool）。
//

import Foundation
import Combine
import SwiftUI

final class SpotifyController: MediaControllerProtocol {

    typealias NetworkAccessEvaluator = @Sendable () async -> Bool

    @Published private var playbackState = PlaybackState(bundleIdentifier: "com.spotify.client")

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool { true }

    // 只要可能拿到 Web API（已授权或还能 refresh）就声明支持 Favorite，UI 才会显示 Like 按钮。
    var supportsFavorite: Bool {
        guard webApiProvider != nil else { return appleScriptProvider.supportsFavorite }
        let keychain = SpotifyKeychainManager.shared
        return keychain.isTokenValid || keychain.refreshToken != nil
    }

    private let appleScriptProvider: SpotifyProvider
    private let webApiProvider: SpotifyProvider?
    private let hasNetworkAccess: NetworkAccessEvaluator

    private var notificationTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var artworkFetchTask: Task<Void, Never>?
    private var lastArtworkURL: String?
    private let commandUpdateDelay: Duration = .milliseconds(25)
    private let pollingInterval: Duration = .seconds(1)

    @MainActor
    convenience init() {
        self.init(
            appleScriptProvider: SpotifyAppleScriptProvider(),
            webApiProvider: SpotifyWebApiProvider(auth: SpotifyAuthManager.shared),
            hasNetworkAccess: {
                // 用户登录过 Web API（keychain 里有 token 或还能 refresh）就视为已配置。
                // 这一刻不主动 refresh —— Web API 内部 validToken() 会按需 refresh，避免每次
                // 命令选 provider 时阻塞等待网络。
                let keychain = SpotifyKeychainManager.shared
                return keychain.isTokenValid || keychain.refreshToken != nil
            }
        )
    }

    init(
        appleScriptProvider: SpotifyProvider,
        webApiProvider: SpotifyProvider?,
        hasNetworkAccess: @escaping NetworkAccessEvaluator
    ) {
        self.appleScriptProvider = appleScriptProvider
        self.webApiProvider = webApiProvider
        self.hasNetworkAccess = hasNetworkAccess

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

    // 仅 Like / Shuffle / Repeat 三个走 Web API（已登录时），需要修改 Spotify 服务端状态、拿三态/Like 信息。
    // 其余播放控制（play/pause/next/previous/seek/volume）始终走 AppleScript，本地即时，不依赖网络。

    func setFavorite(_ favorite: Bool) async {
        guard let trackID = await currentTrackIDForFavoriteAction() else { return }
        await stateProvider().setLiked(favorite, id: trackID)
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }

    func play() async { await appleScriptProvider.play() }
    func pause() async { await appleScriptProvider.pause() }
    func togglePlay() async { await appleScriptProvider.togglePlay() }
    func nextTrack() async { await appleScriptProvider.nextTrack() }

    func previousTrack() async {
        await appleScriptProvider.previousTrack()
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }

    func seek(to time: Double) async {
        await appleScriptProvider.seek(to: time)
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }

    func toggleShuffle() async {
        await stateProvider().setShuffle(!playbackState.isShuffled)
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }

    // 三态循环：off → all (context) → one (track) → off
    func toggleRepeat() async {
        let next: RepeatMode
        switch playbackState.repeatMode {
        case .off: next = .all
        case .all: next = .one
        case .one: next = .off
        }
        await stateProvider().setRepeatMode(next)
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }

    func setVolume(_ level: Double) async {
        let clamped = max(0.0, min(1.0, level))
        await appleScriptProvider.setVolume(Int(clamped * 100))
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }

    nonisolated func isActive() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" }
    }

    func updatePlaybackInfo() async {
        let provider = await stateProvider()
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
            repeatMode: playerState.repeatMode,
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

    // 用于 Like / Shuffle / Repeat 的服务端写操作 + getPlayerState 读全状态。
    // 已登录 Web API 时优先走 Web API；否则降级到 AppleScript（only 两态 repeat，无 Like）。
    private func stateProvider() async -> SpotifyProvider {
        let hasAccess = await hasNetworkAccess()
        guard let webApiProvider, hasAccess else {
            NSLog("[Spotify] state provider -> AppleScript (no token)")
            return appleScriptProvider
        }
        return webApiProvider
    }

    private func currentTrackIDForFavoriteAction() async -> String? {
        let playerState = await stateProvider().getPlayerState()
        return playerState.trackID.isEmpty ? nil : playerState.trackID
    }
}
