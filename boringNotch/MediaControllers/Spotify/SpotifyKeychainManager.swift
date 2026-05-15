//
//  SpotifyKeychainManager.swift
//  boringNotch
//
//  存 access/refresh token、token 过期时间和 Client Secret。
//
//  历史：曾经存在 macOS login keychain。在沙盒 + ad-hoc 签名下反复弹"输入登录密码"
//  且 Always Allow 失效；切到 Data Protection keychain 又因缺 keychain-access-groups
//  entitlement 写入失败。最终改用沙盒私有 UserDefaults：写在
//  ~/Library/Containers/<bundle-id>/Data/Library/Preferences/，其他 App 读不到。
//
//  类名保留 "Keychain" 是为了少改外部调用方；存储后端是 UserDefaults。
//

import Foundation

final class SpotifyKeychainManager {
    static let shared = SpotifyKeychainManager()

    private let store = UserDefaults.standard

    private let clientSecretKey = "theboringteam.boringnotch.spotify_client_secret"
    private let accessTokenKey  = "theboringteam.boringnotch.spotify_access_token"
    private let refreshTokenKey = "theboringteam.boringnotch.spotify_refresh_token"
    private let expiryKey       = "theboringteam.boringnotch.spotify_token_expiry"

    var accessToken: String? {
        get { store.string(forKey: accessTokenKey) }
        set { store.set(newValue, forKey: accessTokenKey) }
    }

    var refreshToken: String? {
        get { store.string(forKey: refreshTokenKey) }
        set { store.set(newValue, forKey: refreshTokenKey) }
    }

    var tokenExpiry: Date? {
        get {
            let ts = store.double(forKey: expiryKey)
            return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
        }
        set {
            if let date = newValue {
                store.set(date.timeIntervalSince1970, forKey: expiryKey)
            } else {
                store.removeObject(forKey: expiryKey)
            }
        }
    }

    var clientSecret: String? {
        get { store.string(forKey: clientSecretKey) }
        set { store.set(newValue, forKey: clientSecretKey) }
    }

    // 60s 缓冲：临近过期就视为无效，触发 refresh。
    var isTokenValid: Bool {
        guard accessToken != nil, let expiry = tokenExpiry else { return false }
        return Date() < expiry.addingTimeInterval(-60)
    }

    func clearTokens() {
        store.removeObject(forKey: accessTokenKey)
        store.removeObject(forKey: refreshTokenKey)
        store.removeObject(forKey: expiryKey)
    }
}
