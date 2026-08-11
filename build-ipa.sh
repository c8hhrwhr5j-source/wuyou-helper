#!/bin/bash
# ===================================================================
# build-ipa.sh —— 把源码目录组装成可被 TrollStore 安装的 .app 并打包成 IPA
#
# 说明: 真正的编译必须在 macOS + Xcode 下完成。本脚本提供两种路径:
#   1) 若本机有 xcodebuild + TrollAutoTouch.xcodeproj (用 xcodegen 生成):
#        执行 ./build-ipa.sh xcode
#   2) 若只想打包一个已编译好的 .app (例如从 Xcode Products 拷出):
#        执行 ./build-ipa.sh payload  path/to/TrollAutoTouch.app
#
# 产物: build/TrollAutoTouch.ipa
# ===================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
PAYLOAD="$BUILD_DIR/Payload"

mkdir -p "$PAYLOAD"
MODE="${1:-help}"

sign_copy_entitlements() {
  local app="$1"
  echo "[*] 注入 entitlements 到 $app"
  # TrollStore 不校验真实签名，但需要 ldid 注入权限 xml 以便 TrollStore 识别
  if command -v ldid >/dev/null 2>&1; then
    ldid -S"$ROOT/TrollAutoTouch/TrollAutoTouch.entitlements" "$app/TrollAutoTouch"
  else
    echo "[!] 未找到 ldid，跳过权限注入。请用 TrollStore 的 ldid 或在 macOS 上 brew install ldid 后重试。"
  fi
}

# ── 准备 App 图标：从源 PNG 生成各尺寸并放到 .app 根目录 ──
prepare_icons() {
  local app="$1"
  local src="$ROOT/TrollAutoTouch_icon.png"

  if [ ! -f "$src" ]; then
    echo "[!] 未找到源图标 $src，跳过图标准备"
    return
  fi

  echo "[*] 准备 App 图标..."

  # 核心文件名（Info.plist CFBundleIconFiles = ["AppIcon"]）
  # iOS 会根据设备从 AppIcon*.png 中选合适尺寸
  cp "$src" "$app/AppIcon.png"

  # 若 macOS 有 sips，生成各尺寸以适配 Retina 屏
  if command -v sips >/dev/null 2>&1; then
    # iPhone 主屏幕 (60pt)
    sips -z 120 120 "$src" --out "$app/AppIcon60x60@2x.png" >/dev/null 2>&1
    sips -z 180 180 "$src" --out "$app/AppIcon60x60@3x.png" >/dev/null 2>&1
    # 设置/通知 (20pt)
    sips -z  40  40 "$src" --out "$app/AppIcon20x20@2x.png" >/dev/null 2>&1
    sips -z  60  60 "$src" --out "$app/AppIcon20x20@3x.png" >/dev/null 2>&1
    # 设置 (29pt)
    sips -z  58  58 "$src" --out "$app/AppIcon29x29@2x.png" >/dev/null 2>&1
    sips -z  87  87 "$src" --out "$app/AppIcon29x29@3x.png" >/dev/null 2>&1
    # Spotlight (40pt)
    sips -z  80  80 "$src" --out "$app/AppIcon40x40@2x.png" >/dev/null 2>&1
    sips -z 120 120 "$src" --out "$app/AppIcon40x40@3x.png" >/dev/null 2>&1
    # iPad (76pt / 83.5pt)
    sips -z 152 152 "$src" --out "$app/AppIcon76x76@2x~ipad.png" >/dev/null 2>&1
    sips -z 167 167 "$src" --out "$app/AppIcon83.5x83.5@2x~ipad.png" >/dev/null 2>&1
    # App Store / 巨魔内部 (1024pt)
    sips -z 1024 1024 "$src" --out "$app/icon-1024.png" >/dev/null 2>&1
    echo "[*] 图标生成完成（sips）"
  else
    # 无 sips 时仅放单张 1024，iOS 会自动缩放
    cp "$src" "$app/icon-1024.png"
    echo "[*] 图标拷贝完成（单文件，iOS 自动缩放）"
  fi
}

case "$MODE" in
  xcode)
    echo "[*] 用 xcodebuild 编译 (Release, 不签名)"
    if [ ! -d "$ROOT/TrollAutoTouch.xcodeproj" ]; then
      echo "[*] 未找到 .xcodeproj，尝试用 xcodegen 生成"
      command -v xcodegen >/dev/null 2>&1 || { echo "[x] 请先安装 xcodegen: brew install xcodegen"; exit 1; }
      (cd "$ROOT" && xcodegen generate)
    fi
    xcodebuild -project "$ROOT/TrollAutoTouch.xcodeproj" \
      -scheme TrollAutoTouch \
      -configuration Release \
      -sdk iphoneos \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      CODE_SIGN_IDENTITY="" \
      -derivedDataPath "$BUILD_DIR/DerivedData" \
      build
    APP="$(find "$BUILD_DIR/DerivedData" -name 'TrollAutoTouch.app' -type d | head -1)"
    [ -z "$APP" ] && { echo "[x] 未找到编译产物 TrollAutoTouch.app"; exit 1; }
    rm -rf "$PAYLOAD"; mkdir -p "$PAYLOAD"
    cp -R "$APP" "$PAYLOAD/"
    prepare_icons "$PAYLOAD/TrollAutoTouch.app"
    sign_copy_entitlements "$PAYLOAD/TrollAutoTouch.app"
    ;;
  payload)
    APP="${2:-}"
    [ -z "$APP" ] && { echo "用法: $0 payload path/to/TrollAutoTouch.app"; exit 1; }
    rm -rf "$PAYLOAD"; mkdir -p "$PAYLOAD"
    cp -R "$APP" "$PAYLOAD/"
    prepare_icons "$PAYLOAD/TrollAutoTouch.app"
    sign_copy_entitlements "$PAYLOAD/TrollAutoTouch.app"
    ;;
  *)
    echo "用法:"
    echo "  $0 xcode                      # 用 xcodebuild 编译并打包"
    echo "  $0 payload <TrollAutoTouch.app>  # 打包已编译的 .app"
    exit 0
    ;;
esac

echo "[*] 打包 IPA"
rm -f "$BUILD_DIR/TrollAutoTouch.ipa"
(cd "$BUILD_DIR" && zip -qry TrollAutoTouch.ipa Payload)
echo "[OK] 产物: $BUILD_DIR/TrollAutoTouch.ipa"
echo "    将该 IPA 通过 AirDrop/网页传入设备，用 TrollStore 打开安装。"
