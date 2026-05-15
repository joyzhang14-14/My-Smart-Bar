//
//  SpotifyAuthManager.swift
//  boringNotch
//
//  Spotify OAuth 2.0 Authorization Code Flow（Client Secret 走 Keychain，
//  Client ID 走 Defaults）。授权完成后 Spotify 跳回 com.joyzhang14.mysmartbar://spotify-callback。
//

import Foundation
import AppKit
import Defaults

@MainActor
final class SpotifyAuthManager: ObservableObject {
    static let shared = SpotifyAuthManager()

    private let redirectURI = "com.joyzhang14.mysmartbar://spotify-callback"
    private let scopes = [
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-library-read",
        "user-library-modify"
    ]

    private let keychain = SpotifyKeychainManager.shared
    @Published var isAuthorized = false

    init() {
        isAuthorized = keychain.isTokenValid || keychain.refreshToken != nil
    }

    var hasConfiguredCredentials: Bool {
        !clientID.isEmpty && !clientSecret.isEmpty
    }

    func startAuthFlow() {
        guard hasConfiguredCredentials else { return }

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "show_dialog", value: "true")
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    func handleCallback(url: URL) async {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else { return }

        await exchangeCode(code)
    }

    private func exchangeCode(_ code: String) async {
        guard hasConfiguredCredentials else { return }
        guard let url = URL(string: "https://accounts.spotify.com/api/token") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic \(basicAuthHeader)", forHTTPHeaderField: "Authorization")
        request.httpBody = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI
        ].urlEncoded

        await performTokenRequest(request)
    }

    func refreshTokenIfNeeded() async {
        guard !keychain.isTokenValid else { return }
        guard hasConfiguredCredentials else {
            isAuthorized = false
            return
        }
        guard let refreshToken = keychain.refreshToken else {
            isAuthorized = false
            return
        }

        guard let url = URL(string: "https://accounts.spotify.com/api/token") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic \(basicAuthHeader)", forHTTPHeaderField: "Authorization")
        request.httpBody = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ].urlEncoded

        await performTokenRequest(request)
    }

    private func performTokenRequest(_ request: URLRequest) async {
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            NSLog("[Spotify] token request transport error")
            return
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
            NSLog("[Spotify] token request -> %d %@", http.statusCode, body)
            return
        }
        guard let json = try? JSONDecoder().decode(SpotifyTokenResponse.self, from: data) else {
            NSLog("[Spotify] token response decode failed")
            return
        }

        keychain.accessToken = json.accessToken
        keychain.tokenExpiry = Date().addingTimeInterval(TimeInterval(json.expiresIn))
        if let refresh = json.refreshToken {
            keychain.refreshToken = refresh
        }
        // 打印实际授予的 scope：用来定位 403 是 scope 缺失（OAuth/Dashboard）还是 access list 问题
        NSLog("[Spotify] token issued, granted scope=%@", json.scope ?? "<missing>")

        isAuthorized = true
        NotificationCenter.default.post(name: .spotifyAuthorizationChanged, object: nil)
    }

    // 业务方调用：自动 refresh 然后返回有效 access token；无凭据时返回 nil 让上游降级到 AppleScript。
    func validToken() async -> String? {
        await refreshTokenIfNeeded()
        return keychain.accessToken
    }

    func signOut() {
        keychain.clearTokens()
        isAuthorized = false
        NotificationCenter.default.post(name: .spotifyAuthorizationChanged, object: nil)
    }

    // 诊断：直接打两个 endpoint 看真实响应，从外部 curl 受限于 sandbox 时用这条路径。
    func runDiagnostics() async {
        NSLog("[Spotify] === diag start ===")
        await diagGet("/v1/me")
        await diagGet("/v1/me/tracks/contains?ids=4iV5W9uYEdYUVa79Axb7Rh")
        NSLog("[Spotify] === diag end ===")
    }

    private func diagGet(_ path: String) async {
        guard let token = await validToken() else {
            NSLog("[Spotify] diag %@ skipped: no token", path)
            return
        }
        guard let base = URL(string: "https://api.spotify.com"),
              let url = URL(string: path, relativeTo: base) else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            NSLog("[Spotify] diag %@ transport error", path)
            return
        }
        let body = String(data: data.prefix(400), encoding: .utf8) ?? "<binary>"
        NSLog("[Spotify] diag %@ -> %d %@", path, http.statusCode, body)
    }

    func handleCredentialChange() {
        if isAuthorized { signOut() }
    }

    // MARK: - Credentials
    private var clientID: String {
        Defaults[.spotifyClientID].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var clientSecret: String {
        (keychain.clientSecret ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func storedClientSecret() -> String { clientSecret }

    func updateClientSecret(_ secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != clientSecret else { return }
        keychain.clientSecret = trimmed.isEmpty ? nil : trimmed
        handleCredentialChange()
    }

    private var basicAuthHeader: String {
        Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
    }
}

private struct SpotifyTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

private extension Dictionary where Key == String, Value == String {
    var urlEncoded: Data? {
        map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
    }
}
