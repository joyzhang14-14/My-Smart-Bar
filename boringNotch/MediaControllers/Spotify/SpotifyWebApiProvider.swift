//
//  SpotifyWebApiProvider.swift
//  boringNotch
//
//  Spotify Web API 客户端。每次请求自动用 AuthManager 拿/刷 token；非 2xx 直接放弃。
//

import Foundation

final class SpotifyWebApiProvider: SpotifyProvider {
    private let auth: SpotifyAuthManager
    private let session: URLSession
    private let baseURL = URL(string: "https://api.spotify.com")!

    init(auth: SpotifyAuthManager, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    let supportsFavorite: Bool = true

    func getPlayerState() async -> SpotifyPlayerState {
        guard let response: SpotifyPlaybackStateResponse = await request("/v1/me/player") else {
            return SpotifyPlayerState()
        }

        let item = response.item
        let trackID = item?.id ?? ""
        let liked = trackID.isEmpty ? false : await isTrackLiked(id: trackID)

        return SpotifyPlayerState(
            isPlaying: response.isPlaying,
            trackName: item?.name ?? "Unknown",
            artist: item?.artists.map(\.name).joined(separator: ", ") ?? "Unknown",
            album: item?.album.name ?? "Unknown",
            position: Double(response.progressMs ?? 0) / 1000,
            duration: Double(item?.durationMs ?? 0) / 1000,
            trackID: trackID,
            shuffle: response.shuffleState,
            repeatMode: RepeatMode.fromSpotifyState(response.repeatState),
            volume: response.device?.volumePercent ?? 50,
            artworkURL: item?.album.images.first?.url ?? "",
            isLiked: liked
        )
    }

    func play() async { _ = await sendCommand("/v1/me/player/play", method: "PUT") }
    func pause() async { _ = await sendCommand("/v1/me/player/pause", method: "PUT") }

    func togglePlay() async {
        let state = await getPlayerState()
        state.isPlaying ? await pause() : await play()
    }

    func nextTrack() async { _ = await sendCommand("/v1/me/player/next", method: "POST") }
    func previousTrack() async { _ = await sendCommand("/v1/me/player/previous", method: "POST") }

    func seek(to time: Double) async {
        let ms = max(0, Int(time * 1000))
        _ = await sendCommand("/v1/me/player/seek?position_ms=\(ms)", method: "PUT")
    }

    func setVolume(_ volume: Int) async {
        let clamped = max(0, min(100, volume))
        _ = await sendCommand("/v1/me/player/volume?volume_percent=\(clamped)", method: "PUT")
    }

    func setShuffle(_ enabled: Bool) async {
        _ = await sendCommand("/v1/me/player/shuffle?state=\(enabled)", method: "PUT")
    }

    func setRepeatMode(_ mode: RepeatMode) async {
        _ = await sendCommand("/v1/me/player/repeat?state=\(mode.spotifyAPIValue)", method: "PUT")
    }

    func isTrackLiked(id: String) async -> Bool {
        let cleanID = normalizedTrackID(from: id)
        guard !cleanID.isEmpty else { return false }
        let encoded = cleanID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cleanID
        guard let result: [Bool] = await request("/v1/me/tracks/contains?ids=\(encoded)") else {
            return false
        }
        return result.first ?? false
    }

    func setLiked(_ liked: Bool, id: String) async {
        let cleanID = normalizedTrackID(from: id)
        guard !cleanID.isEmpty else { return }
        let encoded = cleanID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cleanID
        let method = liked ? "PUT" : "DELETE"
        _ = await sendCommand("/v1/me/tracks?ids=\(encoded)", method: method)
    }

    // MARK: - Private
    private func request<Response: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async -> Response? {
        guard let data = await performRequest(path, method: method, body: body) else { return nil }
        return try? JSONDecoder().decode(Response.self, from: data)
    }

    private func sendCommand(_ path: String, method: String, body: Data? = nil) async -> Bool {
        await performRequest(path, method: method, body: body) != nil
    }

    private func performRequest(_ path: String, method: String, body: Data?) async -> Data? {
        guard let token = await auth.validToken() else {
            NSLog("[Spotify] %@ %@ skipped: no valid token", method, path)
            return nil
        }
        guard let url = URL(string: path, relativeTo: baseURL) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            NSLog("[Spotify] %@ %@ transport error", method, path)
            return nil
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyPreview = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
            NSLog("[Spotify] %@ %@ -> %d  %@", method, path, http.statusCode, bodyPreview)
            return nil
        }
        return data.isEmpty ? Data("{}".utf8) : data
    }

    private func normalizedTrackID(from id: String) -> String {
        id.replacingOccurrences(of: "spotify:track:", with: "")
    }
}

private extension RepeatMode {
    static func fromSpotifyState(_ state: String) -> RepeatMode {
        switch state {
        case "track":   return .one
        case "context": return .all
        default:        return .off
        }
    }

    var spotifyAPIValue: String {
        switch self {
        case .off: return "off"
        case .one: return "track"
        case .all: return "context"
        }
    }
}

// MARK: - Response Models
private struct SpotifyPlaybackStateResponse: Decodable {
    let isPlaying: Bool
    let progressMs: Int?
    let shuffleState: Bool
    let repeatState: String
    let device: SpotifyDevice?
    let item: SpotifyTrack?

    enum CodingKeys: String, CodingKey {
        case isPlaying = "is_playing"
        case progressMs = "progress_ms"
        case shuffleState = "shuffle_state"
        case repeatState = "repeat_state"
        case device, item
    }
}

private struct SpotifyDevice: Decodable {
    let volumePercent: Int

    enum CodingKeys: String, CodingKey {
        case volumePercent = "volume_percent"
    }
}

private struct SpotifyTrack: Decodable {
    let id: String
    let name: String
    let durationMs: Int
    let artists: [SpotifyArtist]
    let album: SpotifyAlbum

    enum CodingKeys: String, CodingKey {
        case id, name, artists, album
        case durationMs = "duration_ms"
    }
}

private struct SpotifyArtist: Decodable { let name: String }
private struct SpotifyAlbum: Decodable { let name: String; let images: [SpotifyImage] }
private struct SpotifyImage: Decodable { let url: String }
