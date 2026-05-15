#!/bin/bash
# 一键发布: build → sign → dmg+zip → 更新 appcast → push → 创建 GitHub release
# 用法: ./scripts/release.sh 1.1.0
set -euo pipefail

VERSION="${1:-}"
REPO_OWNER="joyzhang14-14"
REPO_NAME="My-Smart-Bar"
SIGN_IDENTITY="${SIGN_IDENTITY:-MySmartBarDev}"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "❌ Version must be X.Y.Z (got: '$VERSION')"
  exit 1
fi

# 把 1.1.0 转成 10100，2.7.3 转成 20703，保证单调递增
BUILD=$(echo "$VERSION" | awk -F. '{printf "%d%02d%02d", $1, $2, $3}')

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Checks..."
gh auth status >/dev/null 2>&1 || { echo "❌ gh not authed (run: gh auth login)"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "❌ uncommitted changes — commit/stash first"; exit 1; }
git fetch --tags origin >/dev/null
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null \
   || git ls-remote --tags origin "refs/tags/v$VERSION" | grep -q .; then
  echo "❌ tag v$VERSION already exists"; exit 1
fi

# 找 Sparkle 工具
SPARKLE_BIN=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -path "*sparkle*/bin/generate_appcast" 2>/dev/null | head -1 | xargs -I {} dirname {})
[ -d "$SPARKLE_BIN" ] || { echo "❌ Sparkle tools not found — open Xcode and build once first"; exit 1; }

echo "==> Bumping version: $VERSION (build $BUILD)..."
PBXPROJ="boringNotch.xcodeproj/project.pbxproj"
sed -i '' -E "s/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = $VERSION;/g" "$PBXPROJ"
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $BUILD;/g" "$PBXPROJ"

echo "==> Building Release config (no signing during build)..."
BUILD_DIR="$REPO_ROOT/build"
rm -rf "$BUILD_DIR"
xcodebuild \
  -project boringNotch.xcodeproj \
  -scheme boringNotch \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  clean build 2>&1 | tail -20

APP="$BUILD_DIR/Build/Products/Release/boringNotch.app"
[ -d "$APP" ] || { echo "❌ build failed: $APP not found"; exit 1; }

echo "==> Signing app..."
SIGN_IDENTITY="$SIGN_IDENTITY" "$REPO_ROOT/scripts/sign-app.sh" "$APP"

echo "==> Building DMG..."
DMG_VENV="$REPO_ROOT/Configuration/dmg/.venv"
if [ ! -x "$DMG_VENV/bin/dmgbuild" ]; then
  echo "    Setting up dmgbuild venv (first time only)..."
  python3 -m venv "$DMG_VENV"
  "$DMG_VENV/bin/pip" install --quiet --require-hashes -r "$REPO_ROOT/Configuration/dmg/requirements.txt"
fi
DMG_NAME="MySmartBar-${VERSION}.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
PATH="$DMG_VENV/bin:$PATH" \
  "$REPO_ROOT/Configuration/dmg/create_dmg.sh" "$APP" "$DMG_PATH" "My Smart Bar ${VERSION}"
codesign -f -s "$SIGN_IDENTITY" "$DMG_PATH"
echo "    $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"

echo "==> Packaging zip (for Sparkle delta updates)..."
ZIP_NAME="MySmartBar-${VERSION}.zip"
mkdir -p Releases
rm -f Releases/*.zip
ditto -c -k --keepParent "$APP" "Releases/$ZIP_NAME"
echo "    Releases/$ZIP_NAME ($(du -h "Releases/$ZIP_NAME" | cut -f1))"

echo "==> Generating signed appcast..."
"$SPARKLE_BIN/generate_appcast" \
  --link "https://github.com/${REPO_OWNER}/${REPO_NAME}/releases" \
  --download-url-prefix "https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/v${VERSION}/" \
  -o updater/appcast.xml \
  Releases/

echo "==> Committing & pushing..."
BRANCH=$(git rev-parse --abbrev-ref HEAD)
git add "$PBXPROJ" updater/appcast.xml
git commit -m "chore(release): v${VERSION}"
git push origin "$BRANCH"

echo "==> Creating GitHub release..."
# 直接走 API 创建 release（gh release create 有个误报 workflow scope 的 bug）
gh api -X POST "repos/${REPO_OWNER}/${REPO_NAME}/releases" \
  -f tag_name="v${VERSION}" \
  -f name="v${VERSION}" \
  -f body="Release v${VERSION}" >/dev/null
gh release upload "v${VERSION}" "Releases/$ZIP_NAME" "$DMG_PATH" -R "${REPO_OWNER}/${REPO_NAME}"

echo ""
echo "✅ Released v${VERSION}"
echo "   DMG:     $DMG_PATH (for download)"
echo "   Zip:     Releases/$ZIP_NAME (for Sparkle auto-update)"
echo "   Appcast: updater/appcast.xml"
echo "   Release: https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/tag/v${VERSION}"
