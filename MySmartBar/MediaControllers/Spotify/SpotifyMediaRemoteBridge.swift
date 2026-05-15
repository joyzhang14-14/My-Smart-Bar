//
//  SpotifyMediaRemoteBridge.swift
//  boringNotch
//
//  通过 macOS 私有 MediaRemote.framework 直接给 Spotify（或当前 NowPlaying app）发
//  三态 repeat / shuffle 命令。绕开 Web API（限流 / OAuth）+ AppleScript（只支持 bool）。
//

import Foundation

final class SpotifyMediaRemoteBridge {

    typealias SetRepeatModeFn = @convention(c) (Int) -> Void
    typealias SetShuffleModeFn = @convention(c) (Int) -> Void

    private let setRepeatMode: SetRepeatModeFn
    private let setShuffleMode: SetShuffleModeFn

    init?() {
        guard
            let bundle = CFBundleCreate(
                kCFAllocatorDefault,
                NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")),
            let setRepeatPtr = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetRepeatMode" as CFString),
            let setShufflePtr = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetShuffleMode" as CFString)
        else { return nil }

        setRepeatMode = unsafeBitCast(setRepeatPtr, to: SetRepeatModeFn.self)
        setShuffleMode = unsafeBitCast(setShufflePtr, to: SetShuffleModeFn.self)
    }

    // RepeatMode.rawValue 已经是 off=1 / one=2 / all=3，直接传
    func setRepeat(_ mode: RepeatMode) {
        setRepeatMode(mode.rawValue)
    }

    // Shuffle 的 MediaRemote 编码：off=1, on=3
    func setShuffle(_ enabled: Bool) {
        setShuffleMode(enabled ? 3 : 1)
    }
}
