//
//  SpotifyMediaRemoteBridge.swift
//  boringNotch
//
//  通过 mediaremote-adapter.pl 子进程给当前 NowPlaying app（通常就是 Spotify）发
//  三态 repeat / shuffle 命令。macOS 15.4+ 起 Apple 锁了 MediaRemote 私有 API 的直接
//  in-process 调用，必须通过子进程绕一下（上游 boring.notch 同款方案，跟 NowPlayingController
//  读 streaming 共用同一套 adapter）。
//

import Foundation

final class SpotifyMediaRemoteBridge {

    private let scriptPath: String
    private let frameworkPath: String

    init?() {
        guard
            let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
            let framework = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework")
        else {
            NSLog("[Spotify] MediaRemote adapter not found in bundle")
            return nil
        }
        scriptPath = scriptURL.path
        frameworkPath = framework
    }

    // adapter mode：1=off, 2=one, 3=all（与 RepeatMode.rawValue 一致）
    func setRepeat(_ mode: RepeatMode) {
        run("repeat", String(mode.rawValue))
    }

    // adapter mode：1=off, 3=on
    func setShuffle(_ enabled: Bool) {
        run("shuffle", enabled ? "3" : "1")
    }

    private func run(_ command: String, _ value: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptPath, frameworkPath, command, value]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
            // 等子进程结束以便记录 exit code / stderr —— 操作频次低，几十 ms 阻塞可接受
            process.waitUntilExit()
            let exitCode = process.terminationStatus
            if exitCode != 0 {
                let stderr = String(data: stderrPipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
                NSLog("[Spotify] MediaRemote adapter %@ %@ exit=%d stderr=%@",
                      command, value, exitCode, stderr)
            } else {
                NSLog("[Spotify] MediaRemote adapter %@ %@ ok", command, value)
            }
        } catch {
            NSLog("[Spotify] MediaRemote adapter launch failed: \(error.localizedDescription)")
        }
    }
}
