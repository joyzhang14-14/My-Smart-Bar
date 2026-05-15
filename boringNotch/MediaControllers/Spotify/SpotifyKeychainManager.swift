//
//  SpotifyKeychainManager.swift
//  boringNotch
//
//  把 access/refresh token、token 过期时间和 Client Secret 存进 macOS Keychain。
//

import Foundation
import Security

final class SpotifyKeychainManager {
    static let shared = SpotifyKeychainManager()

    private let clientSecretKey = "theboringteam.boringnotch.spotify_client_secret"
    private let accessTokenKey = "theboringteam.boringnotch.spotify_access_token"
    private let refreshTokenKey = "theboringteam.boringnotch.spotify_refresh_token"
    private let expiryKey = "theboringteam.boringnotch.spotify_token_expiry"

    var accessToken: String? {
        get { read(key: accessTokenKey) }
        set { newValue == nil ? delete(key: accessTokenKey) : save(key: accessTokenKey, value: newValue!) }
    }

    var refreshToken: String? {
        get { read(key: refreshTokenKey) }
        set { newValue == nil ? delete(key: refreshTokenKey) : save(key: refreshTokenKey, value: newValue!) }
    }

    var tokenExpiry: Date? {
        get {
            guard let str = read(key: expiryKey), let ts = Double(str) else { return nil }
            return Date(timeIntervalSince1970: ts)
        }
        set {
            guard let date = newValue else { delete(key: expiryKey); return }
            save(key: expiryKey, value: String(date.timeIntervalSince1970))
        }
    }

    var clientSecret: String? {
        get { read(key: clientSecretKey) }
        set { newValue == nil ? delete(key: clientSecretKey) : save(key: clientSecretKey, value: newValue!) }
    }

    // 60s 缓冲：临近过期就视为无效，触发 refresh。
    var isTokenValid: Bool {
        guard accessToken != nil, let expiry = tokenExpiry else { return false }
        return Date() < expiry.addingTimeInterval(-60)
    }

    func clearTokens() {
        delete(key: accessTokenKey)
        delete(key: refreshTokenKey)
        delete(key: expiryKey)
    }

    // MARK: - Keychain Helpers
    private func save(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecValueData: data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("[Spotify] keychain SAVE failed key=%@ status=%d", key, Int(status))
        }
    }

    private func read(key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status != errSecSuccess {
            NSLog("[Spotify] keychain READ failed key=%@ status=%d", key, Int(status))
            return nil
        }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func delete(key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
