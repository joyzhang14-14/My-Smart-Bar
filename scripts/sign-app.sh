#!/bin/bash
# 分层签名 MySmartBar.app（先签内嵌组件，最后签外壳）
# 用法: ./scripts/sign-app.sh /path/to/MySmartBar.app
set -euo pipefail

APP="${1:-}"
ID="${SIGN_IDENTITY:-MySmartBarDev}"

[ -d "$APP" ] || { echo "❌ App not found: $APP"; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")

TMP_ENT=$(mktemp -t app_ent).plist
trap 'rm -f "$TMP_ENT"' EXIT
sed "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|${BUNDLE_ID}|g" \
  "$REPO_ROOT/MySmartBar/MySmartBar.entitlements" > "$TMP_ENT"

SP="$APP/Contents/Frameworks/Sparkle.framework"
echo "==> Signing Sparkle internals..."
codesign -f -s "$ID" --preserve-metadata=entitlements "$SP/Versions/B/XPCServices/Downloader.xpc"
codesign -f -s "$ID" --preserve-metadata=entitlements "$SP/Versions/B/XPCServices/Installer.xpc"
codesign -f -s "$ID" --preserve-metadata=entitlements "$SP/Versions/B/Updater.app"
codesign -f -s "$ID" "$SP/Versions/B/Autoupdate"
codesign -f -s "$ID" "$SP"

echo "==> Signing other frameworks..."
codesign -f -s "$ID" "$APP/Contents/Frameworks/Lottie.framework"
codesign -f -s "$ID" "$APP/Contents/Frameworks/MediaRemoteAdapter.framework"

echo "==> Signing XPC helper..."
codesign -f -s "$ID" \
  --entitlements "$REPO_ROOT/MySmartBarXPCHelper/MySmartBarXPCHelper.entitlements" \
  "$APP/Contents/XPCServices/MySmartBarXPCHelper.xpc"

echo "==> Signing main app..."
codesign -f -s "$ID" --entitlements "$TMP_ENT" "$APP"

echo "==> Verifying..."
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -3
echo "✅ Signed: $APP"
