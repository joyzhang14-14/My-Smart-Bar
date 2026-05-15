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

    // Like 通过 AppleScript like track 命令实现（add only），不依赖 Web API token，
    // 因此 Spotify 模式下始终支持。
    var supportsFavorite: Bool { true }

    private let appleScriptProvider: SpotifyProvider
    private let webApiProvider: SpotifyProvider?
    private let hasNetworkAccess: NetworkAccessEvaluator
    // MediaRemote 私有 framework，唯一支持三态 repeat 的本地通道
    private let mediaRemote: SpotifyMediaRemoteBridge? = SpotifyMediaRemoteBridge()

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
        // 走 AppleScript 而非 Web API：Spotify Development Mode 下 /v1/me/tracks 一律 403
        // （即使 user-library-modify scope 拿到、user 加入 Users and Access 也不行）。
        // AppleScript like track 由 Spotify 桌面端处理，会同步到服务端的 Liked Songs。
        // 因为读不到 is_liked 状态，UI 心形永远显示空心 → 这里也只接受 add（liked=true）。
        NSLog("[Spotify] setFavorite(%@) via AppleScript", favorite ? "true" : "false")
        await appleScriptProvider.setLiked(favorite, id: "")
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
        let target = !playbackState.isShuffled
        NSLog("[Spotify] toggleShuffle invoked: %@ -> %@",
              playbackState.isShuffled ? "on" : "off",
              target ? "on" : "off")
        // 首选 MediaRemote（本地、无限流、即时生效）；不可用时退到 AppleScript
        if let mediaRemote {
            mediaRemote.setShuffle(target)
        } else {
            _ = await appleScriptProvider.setShuffle(target)
        }
        // 立即把意图同步到 cached state，避免随后的 AppleScript 读把状态又拽回来
        playbackState.isShuffled = target
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }

    // 三态循环：off → all (context) → one (track) → off
    // MediaRemote 三态都支持；MediaRemote 不可用时退到 AppleScript 的 bool。
    // cached 的 repeatMode 视作"用户意图"——立即推进，AppleScript 读不会覆盖（见 updatePlaybackInfo）。
    func toggleRepeat() async {
        let next: RepeatMode
        switch playbackState.repeatMode {
        case .off: next = .all
        case .all: next = .one
        case .one: next = .off
        }
        NSLog("[Spotify] toggleRepeat invoked: %@ -> %@",
              String(describing: playbackState.repeatMode),
              String(describing: next))
        if let mediaRemote {
            mediaRemote.setRepeat(next)
        } else {
            NSLog("[Spotify] toggleRepeat: MediaRemote unavailable, falling back to AppleScript")
            _ = await appleScriptProvider.setRepeatMode(next)
        }
        // 立即把 cached state 推进到用户意图，AppleScript bool 读不会覆盖（updatePlaybackInfo 内处理）
        playbackState.repeatMode = next
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
        var playerState = await provider.getPlayerState()
        var readViaAppleScript = (provider === appleScriptProvider)

        // Web API /v1/me/player 在云端没把桌面端标成 active device 时会返 204，
        // 解出来是默认值（trackName="Unknown", duration=0）。此时桌面 App 还在播，
        // 回退到 AppleScript 直接问桌面 App 拿真实状态。
        if playerState.duration == 0,
           playerState.trackName == "Unknown",
           isActive(),
           provider !== appleScriptProvider {
            playerState = await appleScriptProvider.getPlayerState()
            readViaAppleScript = true
        }

        // AppleScript 读 repeat 只能拿到 bool，会把刚 toggle 出来的 .one 退成 .all。
        // 走 AppleScript 路径时保留 cached repeatMode（即 toggleRepeat 推进的用户意图）。
        let resolvedRepeatMode: RepeatMode = readViaAppleScript
            ? playbackState.repeatMode
            : playerState.repeatMode

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
            repeatMode: resolvedRepeatMode,
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
    // 限流冷却期间也直接走 AppleScript——否则轮询每秒都在 performRequest 里打一行 "skipped"。
    private func stateProvider() async -> SpotifyProvider {
        let hasAccess = await hasNetworkAccess()
        guard let webApiProvider, hasAccess else {
            NSLog("[Spotify] state provider -> AppleScript (no token)")
            return appleScriptProvider
        }
        if let webApi = webApiProvider as? SpotifyWebApiProvider, webApi.isRateLimited {
            return appleScriptProvider
        }
        return webApiProvider
    }

}
