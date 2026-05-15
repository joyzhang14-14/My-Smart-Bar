//
//  NetEaseLyricsClient.swift
//  boringNotch
//
//  在 app 内直接实现网易云音乐 weapi 加密接口，作为 lrclib 失败时的歌词 fallback。
//  对应 https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced 的 crypto/search/lyric 三段，
//  这样用户不再需要自部署 Docker / Node server。
//

import CommonCrypto
import Foundation
import Security

enum NetEaseLyricsClient {
    // MARK: - Public

    /// 给定歌名 + 歌手名，返回（plain, synced）歌词文本。
    /// synced 已经过 normalizeNetEaseLRC 转换成纯净的 `[mm:ss.xx]Line` 标准 LRC，
    /// 调用方（MusicManager.parseLRC）可以按统一的标准格式处理，不需要懂 NetEase 方言。
    static func fetchLyrics(title: String, artist: String, durationSeconds: Double = 0) async -> (plain: String, synced: String)? {
        guard let songID = await searchSongID(title: title, artist: artist, durationSeconds: durationSeconds) else {
            NSLog("[Lyrics][NetEase native] no song match for \"\(title)\" - \"\(artist)\"")
            return nil
        }
        guard let raw = await fetchLRC(songID: songID) else {
            NSLog("[Lyrics][NetEase native] no lyric for song id \(songID)")
            return nil
        }
        let synced = normalizeNetEaseLRC(raw)
        if synced.isEmpty {
            NSLog("[Lyrics][NetEase native] normalized LRC empty for song id \(songID)")
            return nil
        }
        let plain = stripLRCTimestamps(synced)
        return (plain: plain, synced: synced)
    }

    /// 把 NetEase 自家的 LRC 方言转成标准 LRC：
    ///   - `[mm:ss.xxx]`  3 位毫秒    → 截成 2 位百分秒
    ///   - `[mm:ss.xx-N]` 元数据 / 翻译标记 → 整行丢掉
    ///   - `[ti:]/[ar:]/[al:]/[by:]/[offset:]` ID3 标签 → 整行丢掉
    ///   - 时间 `00:00.00` 且文本含 `:` → 元数据（"作词:XXX"）→ 丢掉
    /// 输出每行都是 `[mm:ss.xx]text` 标准格式，对 lrclib 友好的 parseLRC 友好。
    /// 公开是因为 MusicManager 的"自部署 api-enhanced server"路径也要复用。
    static func normalizeNetEaseLRC(_ raw: String) -> String {
        let pattern = #"^\s*\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?(-\d+)?\]\s*(.*?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return raw }

        var lines: [String] = []
        for sub in raw.split(separator: "\n") {
            let line = String(sub)
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
                continue
            }
            // -N 后缀 = NetEase 元数据 / 翻译标记
            if m.range(at: 4).location != NSNotFound { continue }

            let mm = ns.substring(with: m.range(at: 1))
            let ss = ns.substring(with: m.range(at: 2))
            var cs = "00"
            if m.range(at: 3).location != NSNotFound {
                let frac = ns.substring(with: m.range(at: 3))
                cs = String((frac + "00").prefix(2))
            }
            let text = ns.substring(with: m.range(at: 5))
            if text.isEmpty { continue }
            // 启发式：00:00.00 + 文本含 ":" → 多半是 "作词 : XXX" 之类元数据
            if mm == "00" && ss == "00" && cs == "00" && text.contains(":") { continue }

            lines.append("[\(mm):\(ss).\(cs)]\(text)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Endpoints

    private static func searchSongID(title: String, artist: String, durationSeconds: Double) async -> Int? {
        // 用新版 cloudsearch/pc 端点，不是老的 search/get / cloudsearch/get/web。
        // 老端点对未登录请求会返回 code:50000005（反爬）。
        let query = artist.isEmpty ? title : "\(title) \(artist)"
        let body: [String: Any] = [
            "s": query,
            "type": 1,
            "limit": 10,         // 多取几条，下面按 artist + title 打分挑最准的一条
            "offset": 0,
            "total": true,
            "csrf_token": ""
        ]
        guard let json = jsonString(body),
              let resp = await postWeapi(path: "/cloudsearch/pc", paramsJSON: json) else {
            return nil
        }
        guard let result = resp["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]],
              !songs.isEmpty else {
            return nil
        }
        return pickBestMatch(from: songs, title: title, artist: artist, durationSeconds: durationSeconds)
    }

    /// 在 NetEase 返回的多条候选里挑最匹配的一首。
    /// 打分：歌名包含/被包含 +10；用户指定的每个艺人在结果艺人列表里能找到 +1；
    /// 候选时长与当前播放接近 +5（≤3s 偏差）或 +2（≤10s 偏差）——这一项对挑对版本至关重要：
    /// "Die With A Smile" 单曲版 vs "Die With A Smile (Live)" 时长往往差几十秒，
    /// 没有时长卡 LRC 可能选到错版本，整段时间线就全偏。
    /// 全 0 分时（极少见）退化为第一条，免得无歌词。
    private static func pickBestMatch(from songs: [[String: Any]], title: String, artist: String, durationSeconds: Double) -> Int? {
        let normalizedTitle = normalizeForMatch(title)
        // "Lady Gaga, Bruno Mars" → ["lady gaga", "bruno mars"]
        let userArtists = artist
            .split(whereSeparator: { $0 == "," || $0 == "&" || $0 == "/" })
            .map { normalizeForMatch(String($0)) }
            .filter { !$0.isEmpty }

        var best: (id: Int, score: Int, name: String, artists: String)? = nil
        for song in songs {
            guard let id = song["id"] as? Int else { continue }
            let songName = (song["name"] as? String) ?? ""
            // 歌名的所有可比较变体：主名 + tns（翻译/别名，比如英文版）+ alia（备选名，比如带 (Live) 后缀的）
            let songNameVariants: [String] = {
                var all: [String] = [songName]
                if let tns = song["tns"] as? [String] { all.append(contentsOf: tns) }
                if let alia = song["alia"] as? [String] { all.append(contentsOf: alia) }
                return all.map { normalizeForMatch($0) }.filter { !$0.isEmpty }
            }()

            // 艺人列表：优先 cloudsearch/pc 的 ar；老 search/get 回 artists。
            // 每个艺人除了 name 还可能有 tns（如 周杰伦.tns = ["Jay Chou"]），统一拍平后比对。
            let artistNameVariants: [[String]] = {
                let raw = (song["ar"] as? [[String: Any]])
                    ?? (song["artists"] as? [[String: Any]])
                    ?? []
                return raw.map { entry -> [String] in
                    var names: [String] = []
                    if let n = entry["name"] as? String { names.append(n) }
                    if let tns = entry["tns"] as? [String] { names.append(contentsOf: tns) }
                    if let alias = entry["alias"] as? [String] { names.append(contentsOf: alias) }
                    return names.map { normalizeForMatch($0) }.filter { !$0.isEmpty }
                }
            }()

            var score = 0
            // title 命中：用户标题在任一变体里出现，或反过来
            if !normalizedTitle.isEmpty,
               songNameVariants.contains(where: { $0.contains(normalizedTitle) || normalizedTitle.contains($0) }) {
                score += 10
            }
            // 每个用户艺人：在任一艺人的任一名字变体里出现 +1
            for ua in userArtists where !ua.isEmpty {
                let matched = artistNameVariants.contains { variants in
                    variants.contains { $0.contains(ua) || ua.contains($0) }
                }
                if matched { score += 1 }
            }
            // 时长匹配：dt 字段是毫秒整数
            if durationSeconds > 0, let dt = song["dt"] as? Int {
                let candidateSec = Double(dt) / 1000.0
                let diff = abs(candidateSec - durationSeconds)
                if diff <= 3 { score += 5 }
                else if diff <= 10 { score += 2 }
            }

            if best == nil || score > best!.score {
                // 日志里只显示主名，方便排查
                let primaryArtists = artistNameVariants.compactMap { $0.first }.joined(separator: ", ")
                best = (id, score, songName, primaryArtists)
            }
        }

        // 阈值：title 必须命中（+10），否则视为没有合理匹配，整个 source 当 miss
        // 处理。宁可不显示，也不要给一首完全不相干的歌的歌词（之前会显示同名翻唱、
        // 同时长不同曲等"假装匹配"）。
        if let best = best, best.score >= 10 {
            NSLog("[Lyrics][NetEase native] picked id=\(best.id) score=\(best.score) — \"\(best.name)\" by \"\(best.artists)\"")
            return best.id
        }
        if let best = best {
            NSLog("[Lyrics][NetEase native] rejected best candidate (score=\(best.score) < 10) — \"\(best.name)\" by \"\(best.artists)\"")
        }
        return nil
    }

    private static func normalizeForMatch(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
    }

    private static func fetchLRC(songID: Int) async -> String? {
        let body: [String: Any] = [
            "id": songID,
            "lv": -1,
            "tv": -1,
            "csrf_token": ""
        ]
        guard let json = jsonString(body),
              let resp = await postWeapi(path: "/song/lyric", paramsJSON: json) else {
            return nil
        }
        guard let lrc = (resp["lrc"] as? [String: Any])?["lyric"] as? String else {
            return nil
        }
        let trimmed = lrc.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - HTTP

    private static func postWeapi(path: String, paramsJSON: String) async -> [String: Any]? {
        guard let encrypted = encryptWeapi(json: paramsJSON) else {
            NSLog("[Lyrics][NetEase native] encrypt failed for \(path)")
            return nil
        }
        guard let url = URL(string: "https://music.163.com/weapi\(path)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // 这一套 UA + cookies 完全照抄 api-enhanced 的 weapi 配置（util/request.js）。
        // 缺任何一个字段都可能触发反爬返回 code:50000005。
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0", forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue(buildWeapiCookie(), forHTTPHeaderField: "Cookie")

        let bodyStr = "params=\(formURLEncode(encrypted.params))&encSecKey=\(formURLEncode(encrypted.encSecKey))"
        req.httpBody = bodyStr.data(using: .utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard http.statusCode == 200 else {
                NSLog("[Lyrics][NetEase native] \(path) HTTP \(http.statusCode)")
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("[Lyrics][NetEase native] \(path) response not JSON")
                return nil
            }
            if let code = json["code"] as? Int, code != 200 {
                NSLog("[Lyrics][NetEase native] \(path) api code \(code)")
                // 不直接 return nil —— 搜歌时 code 可能不等于 200 但 result 仍可用，保留兼容
            }
            return json
        } catch {
            NSLog("[Lyrics][NetEase native] \(path) error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Crypto

    // 这两个常量、IV、公钥都来自 NetEase 官方 weapi 端的写死值；
    // 与 api-enhanced 的 util/crypto.js 一字不差。
    private static let presetKey = "0CoJUm6Qyw8W8jud"
    private static let weapiIV = "0102030405060708"
    private static let base62Alphabet = "PJArHa0gu8yfrFDLkRTiZcOqGS6dlnex4VtmsbpYwjvK1z3M9NoIBQEh2WUXC75"

    // NetEase weapi RSA 公钥（1024-bit），原始 X.509 SubjectPublicKeyInfo 的 Base64 形式。
    // 等价于 api-enhanced 里 -----BEGIN PUBLIC KEY----- 块的 PEM body。
    private static let publicKeySPKIBase64 = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB"

    private static func encryptWeapi(json: String) -> (params: String, encSecKey: String)? {
        // 第一层：用 presetKey 加密原始 JSON
        guard let firstPass = aesCBCPKCS7Encrypt(plaintext: json, key: presetKey, iv: weapiIV) else {
            return nil
        }
        let firstPassB64 = firstPass.base64EncodedString()

        // 第二层：随机生成 16 位 secretKey，再次加密
        let secretKey = randomBase62String(length: 16)
        guard let secondPass = aesCBCPKCS7Encrypt(plaintext: firstPassB64, key: secretKey, iv: weapiIV) else {
            return nil
        }
        let params = secondPass.base64EncodedString()

        // RSA 加密 secretKey（reverse 后左侧零填充到 128 字节，no-padding）
        let keyBytes = Array(secretKey.utf8)
        let reversed = Data(keyBytes.reversed())
        var padded = Data(count: 128 - reversed.count)
        padded.append(reversed)
        guard let encryptedKey = rsaEncryptNoPadding(padded) else { return nil }
        let encSecKey = encryptedKey.map { String(format: "%02x", $0) }.joined()

        return (params, encSecKey)
    }

    private static func aesCBCPKCS7Encrypt(plaintext: String, key: String, iv: String) -> Data? {
        guard let textData = plaintext.data(using: .utf8),
              let keyData = key.data(using: .utf8),
              let ivData = iv.data(using: .utf8) else {
            return nil
        }
        let bufferSize = textData.count + kCCBlockSizeAES128
        var output = Data(count: bufferSize)
        var outputLength: size_t = 0

        let status = output.withUnsafeMutableBytes { outBuf -> CCCryptorStatus in
            textData.withUnsafeBytes { inBuf in
                keyData.withUnsafeBytes { keyBuf in
                    ivData.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, kCCKeySizeAES128,
                            ivBuf.baseAddress,
                            inBuf.baseAddress, textData.count,
                            outBuf.baseAddress, bufferSize,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            NSLog("[Lyrics][NetEase native] CCCrypt status \(status)")
            return nil
        }
        return output.prefix(outputLength)
    }

    private static func rsaEncryptNoPadding(_ data: Data) -> Data? {
        guard data.count == 128 else {
            NSLog("[Lyrics][NetEase native] RSA input must be 128 bytes, got \(data.count)")
            return nil
        }
        guard let pkcs1KeyData = pkcs1PublicKey() else {
            NSLog("[Lyrics][NetEase native] failed to extract PKCS#1 from SPKI")
            return nil
        }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 1024
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(pkcs1KeyData as CFData, attrs as CFDictionary, &error) else {
            NSLog("[Lyrics][NetEase native] SecKeyCreateWithData failed: \(error?.takeRetainedValue().localizedDescription ?? "?")")
            return nil
        }
        guard SecKeyIsAlgorithmSupported(secKey, .encrypt, .rsaEncryptionRaw) else {
            NSLog("[Lyrics][NetEase native] rsaEncryptionRaw not supported")
            return nil
        }
        guard let encrypted = SecKeyCreateEncryptedData(secKey, .rsaEncryptionRaw, data as CFData, &error) else {
            NSLog("[Lyrics][NetEase native] SecKeyCreateEncryptedData failed: \(error?.takeRetainedValue().localizedDescription ?? "?")")
            return nil
        }
        return encrypted as Data
    }

    // 把 PEM 里 SPKI 包装 (X.509 SubjectPublicKeyInfo) 剥成 PKCS#1 (RSAPublicKey)。
    // 对 1024-bit RSA 公钥而言，SPKI 前缀固定 22 字节，剩下就是 PKCS#1。
    private static func pkcs1PublicKey() -> Data? {
        guard let spki = Data(base64Encoded: publicKeySPKIBase64), spki.count > 22 else {
            return nil
        }
        return spki.subdata(in: 22..<spki.count)
    }

    // MARK: - Cookies

    // 构造一组完整的 cookie 字符串，模拟"已注册但未登录"的 web 客户端。
    // 字段集合 + 默认值与 api-enhanced 的 processCookieObject 对齐；NetEase 用这些 cookie
    // 判断是否合法 web 客户端，缺字段就 50000005 反爬。
    private static func buildWeapiCookie() -> String {
        let nuid = randomHex(length: 32)
        let nmtid = randomHex(length: 16)
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let wnmcid = "\(randomLowerLetters(length: 6)).\(timestamp).01.0"

        let pairs: [(String, String)] = [
            ("__remember_me", "true"),
            ("ntes_kaola_ad", "1"),
            ("_ntes_nuid", nuid),
            ("_ntes_nnid", "\(nuid),\(timestamp)"),
            ("WNMCID", wnmcid),
            ("WEVNSM", "1.0.0"),
            ("osver", "Microsoft-Windows-10-Professional-build-19045-64bit"),
            ("os", "pc"),
            ("channel", "netease"),
            ("appver", "3.1.17.204416"),
            ("NMTID", nmtid),
            ("MUSIC_A", "")
        ]
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    // MARK: - Helpers

    private static func randomHex(length: Int) -> String {
        let chars = Array("0123456789abcdef")
        var out = ""
        for _ in 0..<length { out.append(chars[Int.random(in: 0..<chars.count)]) }
        return out
    }

    private static func randomLowerLetters(length: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz")
        var out = ""
        for _ in 0..<length { out.append(chars[Int.random(in: 0..<chars.count)]) }
        return out
    }

    private static func randomBase62String(length: Int) -> String {
        let chars = Array(base62Alphabet)
        var out = ""
        for _ in 0..<length {
            out.append(chars[Int.random(in: 0..<chars.count)])
        }
        return out
    }

    private static func jsonString(_ obj: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // application/x-www-form-urlencoded 严格编码：保留 字母数字 - . _ * 其它全部 %XX
    private static func formURLEncode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._*")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // 剥掉标准 [mm:ss.xx] 时间戳。输入应该是 normalizeNetEaseLRC 处理过的纯净 LRC。
    private static func stripLRCTimestamps(_ lrc: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[\d{1,2}:\d{2}(?:\.\d{1,2})?\]"#) else {
            return lrc
        }
        let ns = lrc as NSString
        let stripped = regex.stringByReplacingMatches(
            in: lrc,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: ""
        )
        return stripped
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
