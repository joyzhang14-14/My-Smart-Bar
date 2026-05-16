//
//  QQMusicLyricsClient.swift
//  boringNotch
//
//  QQ 音乐歌词客户端：作为 NetEase 失败时的 fallback。
//  接口比 NetEase 简单——不需要 weapi 加密，只是 JSON 包参数 + Referer 头。
//
//  Search:
//    GET https://c.y.qq.com/soso/fcgi-bin/client_search_cp
//    返回 data.song.list[].songmid + interval(秒)
//
//  Lyric:
//    GET https://u.y.qq.com/cgi-bin/musicu.fcg?data=<JSON>
//    返回 req.data.lyric (base64 编码的标准 LRC)
//

import Foundation

enum QQMusicLyricsClient {
    // MARK: - Public

    static func fetchLyrics(title: String, artist: String, durationSeconds: Double = 0) async -> (plain: String, synced: String)? {
        guard let songmid = await searchSongMID(title: title, artist: artist, durationSeconds: durationSeconds) else {
            NSLog("[Lyrics][QQ] no song match for \"\(title)\" - \"\(artist)\"")
            return nil
        }
        guard let raw = await fetchLRC(songmid: songmid) else {
            NSLog("[Lyrics][QQ] no lyric for songmid \(songmid)")
            return nil
        }
        // QQ 的 LRC 一般已是标准 [mm:ss.xx] 格式，但偶尔有 [ti:]/[ar:]/[al:] ID3 标签和
        // 形如 [00:00.00]Title-Artist 的元数据行。复用 NetEase 的 normalizer 把这些都剥掉。
        let synced = NetEaseLyricsClient.normalizeNetEaseLRC(raw)
        if synced.isEmpty {
            NSLog("[Lyrics][QQ] normalized LRC empty for songmid \(songmid)")
            return nil
        }
        let plain = stripLRCTimestamps(synced)
        return (plain: plain, synced: synced)
    }

    // MARK: - Search

    private static func searchSongMID(title: String, artist: String, durationSeconds: Double) async -> String? {
        let query = artist.isEmpty ? title : "\(title) \(artist)"
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?w=\(encoded)&p=1&n=10&format=json&cr=1") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                NSLog("[Lyrics][QQ] search non-200: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataDict = json["data"] as? [String: Any],
                  let song = dataDict["song"] as? [String: Any],
                  let list = song["list"] as? [[String: Any]],
                  !list.isEmpty else {
                return nil
            }
            return pickBestMatch(from: list, title: title, artist: artist, durationSeconds: durationSeconds)
        } catch {
            NSLog("[Lyrics][QQ] search error: \(error.localizedDescription)")
            return nil
        }
    }

    /// 同 NetEaseLyricsClient.pickBestMatch 同样的打分思路：title 包含 +10、每个艺人 +1、
    /// 时长接近 +5/+2。QQ 的字段名不同：歌曲叫 songname / 艺人在 singer[].name / 时长是 interval(秒)。
    private static func pickBestMatch(from songs: [[String: Any]], title: String, artist: String, durationSeconds: Double) -> String? {
        let normalizedTitle = normalizeForMatch(title)
        let userArtists = artist
            .split(whereSeparator: { $0 == "," || $0 == "&" || $0 == "/" })
            .map { normalizeForMatch(String($0)) }
            .filter { !$0.isEmpty }

        var best: (mid: String, score: Int, name: String, artists: String)? = nil
        var rejectedForDuration = 0
        for song in songs {
            guard let mid = song["songmid"] as? String, !mid.isEmpty else { continue }
            // 时长硬过滤：interval 与 songDuration 偏差 >3s 整条候选直接弃用。
            // durationSeconds == 0 时跳过过滤；候选缺 interval 字段时也跳过（保守不误杀）。
            if durationSeconds > 0, let interval = song["interval"] as? Int {
                if abs(Double(interval) - durationSeconds) > 3 {
                    rejectedForDuration += 1
                    continue
                }
            }
            let songName = (song["songname"] as? String) ?? ""
            let singerNames: [String] = ((song["singer"] as? [[String: Any]]) ?? [])
                .compactMap { $0["name"] as? String }

            let normalizedSongName = normalizeForMatch(songName)
            let normalizedSingers = singerNames.map { normalizeForMatch($0) }

            var score = 0
            if !normalizedTitle.isEmpty,
               normalizedSongName.contains(normalizedTitle) || normalizedTitle.contains(normalizedSongName) {
                score += 10
            }
            for ua in userArtists where !ua.isEmpty {
                if normalizedSingers.contains(where: { $0.contains(ua) || ua.contains($0) }) {
                    score += 1
                }
            }
            // QQ 的 interval 直接是秒（不像 NetEase 的 dt 是毫秒）
            if durationSeconds > 0, let interval = song["interval"] as? Int {
                let diff = abs(Double(interval) - durationSeconds)
                if diff <= 3 { score += 5 }
                else if diff <= 10 { score += 2 }
            }

            if best == nil || score > best!.score {
                best = (mid, score, songName, singerNames.joined(separator: ", "))
            }
        }

        // 同 NetEase：title 必须命中（+10），否则当 miss，避免给同名翻唱的歌词。
        if let best = best, best.score >= 10 {
            NSLog("[Lyrics][QQ] picked mid=\(best.mid) score=\(best.score) — \"\(best.name)\" by \"\(best.artists)\"")
            return best.mid
        }
        if let best = best {
            NSLog("[Lyrics][QQ] rejected best candidate (score=\(best.score) < 10) — \"\(best.name)\" by \"\(best.artists)\"")
        } else if rejectedForDuration > 0 {
            NSLog("[Lyrics][QQ] rejected all \(rejectedForDuration) candidates by ±3s duration filter")
        }
        return nil
    }

    // MARK: - Lyric

    private static func fetchLRC(songmid: String) async -> String? {
        // musicu.fcg 接受 URL-encoded JSON，包含 module/method/param 三段
        let payload: [String: Any] = [
            "comm": ["ct": 24, "cv": 0],
            "req": [
                "module": "music.musichallSong.PlayLyricInfo",
                "method": "GetPlayLyricInfo",
                "param": ["songMID": songmid]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonStr = String(data: data, encoding: .utf8),
              let encoded = jsonStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg?data=\(encoded)") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        do {
            let (responseData, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                NSLog("[Lyrics][QQ] lyric non-200: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let reqDict = json["req"] as? [String: Any],
                  let dataDict = reqDict["data"] as? [String: Any],
                  let b64 = dataDict["lyric"] as? String,
                  !b64.isEmpty else {
                NSLog("[Lyrics][QQ] lyric: empty req.data.lyric")
                return nil
            }
            guard let decodedData = Data(base64Encoded: b64),
                  let lrc = String(data: decodedData, encoding: .utf8) else {
                NSLog("[Lyrics][QQ] lyric: base64 decode failed")
                return nil
            }
            let trimmed = lrc.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            NSLog("[Lyrics][QQ] lyric error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Helpers

    private static func normalizeForMatch(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
    }

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
