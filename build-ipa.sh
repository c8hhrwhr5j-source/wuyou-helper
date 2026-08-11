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
    sign_copy_entitlements "$PAYLOAD/TrollAutoTouch.app"
    ;;
  payload)
    APP="${2:-}"
    [ -z "$APP" ] && { echo "用法: $0 payload path/to/TrollAutoTouch.app"; exit 1; }
    rm -rf "$PAYLOAD"; mkdir -p "$PAYLOAD"
    cp -R "$APP" "$PAYLOAD/"
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
