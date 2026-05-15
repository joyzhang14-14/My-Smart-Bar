<div align="center">
  <img src=".github/icon.png" alt="My Smart Bar" width="128" height="128" />

  <h1>My Smart Bar</h1>

  <p>A native macOS app that turns the MacBook notch into a useful, interactive control center.</p>

  <a href="https://github.com/joyzhang14-14/My-Smart-Bar/releases/latest">
    <img src="https://img.shields.io/github/v/release/joyzhang14-14/My-Smart-Bar?label=download&style=flat-square" alt="latest release" />
  </a>
</div>

---

## Features

- **Now Playing** — playback controls with synced lyrics for Spotify (Web API) and Apple Music
- **Shelf** — drag files into the notch as a temporary clipboard
- **HUD** — replaces the macOS volume / brightness / keyboard backlight overlay
- **Battery** — charging state and percentage at a glance
- **Camera mirror** — peek at the front camera under the notch
- **Calendar** — quick view of upcoming events
- **Gestures** — swipe to skip tracks, scroll to adjust volume

## Install

1. Download `MySmartBar-X.Y.Z.dmg` from [the latest release](https://github.com/joyzhang14-14/My-Smart-Bar/releases/latest)
2. Open the DMG and drag the app into `Applications`
3. **First launch:** right-click the app → **Open** (the app uses a self-signed certificate, so Gatekeeper needs manual approval once)

After that, the app silently checks for updates on launch.

## Auto-updates

Updates ship via [Sparkle](https://sparkle-project.org). The app reads an [appcast](updater/appcast.xml) that's signed with an EdDSA key, so updates are tamper-proof end-to-end. No App Store, no account required.

## Build from source

Requires **Xcode 16+** on **macOS 14+**.

```bash
git clone https://github.com/joyzhang14-14/My-Smart-Bar.git
cd My-Smart-Bar
open MySmartBar.xcodeproj
# Cmd+R to run
```

## Cutting a release

Local Makefile-driven pipeline (build → sign → DMG + ZIP → signed appcast → GitHub release):

```bash
make app 1.2.0
```

Requires the `MySmartBarDev` code-signing certificate in your keychain and a one-time `gh auth login`. See [`scripts/release.sh`](scripts/release.sh) for the full flow.

## Credits

Forked from [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch) — the upstream team built the entire foundation. This fork is a personal flavor with its own signing identity, release pipeline, and icon.

## License

Same as upstream — see [LICENSE](LICENSE).
