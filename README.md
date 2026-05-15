<div align="center">
  <img src=".github/icon.png" alt="My Smart Bar" width="128" height="128" />

  <h1>My Smart Bar</h1>

  <p>A native macOS app that turns the MacBook notch into a useful, interactive control center.</p>

  <a href="https://github.com/joyzhang14-14/My-Smart-Bar/releases/latest">
    <img src="https://img.shields.io/github/v/release/joyzhang14-14/My-Smart-Bar?label=download&style=flat-square" alt="latest release" />
  </a>
</div>

---

## Install

1. Download `MySmartBar-X.Y.Z.dmg` from [the latest release](https://github.com/joyzhang14-14/My-Smart-Bar/releases/latest).
2. The app uses a self-signed certificate, so Gatekeeper will block it. Pick one of these to bypass it:

   **Option A — strip quarantine (no prompts):**
   ```bash
   xattr -dr com.apple.quarantine ~/Downloads/MySmartBar-*.dmg
   ```
   Then open the DMG and drag the app into `Applications` — first launch just works.

   **Option B — manually approve once:**
   Open the DMG, drag into `Applications`, then **right-click the app → Open → Open** in the warning dialog. Only needed on first launch.

After install, the app silently checks for updates on launch via Sparkle.

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

## Credits

Forked from [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch) — the upstream team built the entire foundation. This fork is a personal flavor with its own signing identity, release pipeline, and icon.

