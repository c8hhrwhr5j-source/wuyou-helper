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

# 验证注入结果中的关键权限键是否齐全
# 缺失任何一个都说明注入失败，直接报错退出（避免产出"阉割版" IPA）
verify_entitlements() {
  local app="$1"
  local bin="$app/TrollAutoTouch"
  echo "[*] 验证注入结果..."
  if ! command -v ldid >/dev/null 2>&1; then
    echo "[x] 找不到 ldid，无法验证。请先安装: brew install ldid"
    exit 1
  fi
  local extracted
  extracted="$(ldid -e "$bin" 2>/dev/null || true)"
  local required=(
    "com.apple.private.security.no-sandbox"
    "platform-application"
    "com.apple.private.tcc.allow"
    "keychain-access-groups"
    "com.apple.private.security.container-manager"
  )
  local missing=()
  for k in "${required[@]}"; do
    if ! printf '%s' "$extracted" | grep -q "$k"; then
      missing+=("$k")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "[x] entitlements 注入失败，缺失以下关键权限:"
    printf '    - %s\n' "${missing[@]}"
    echo "    请检查: 1) ldid 是否可用 (brew install ldid)  2) TrollAutoTouch.entitlements 文件内容"
    exit 1
  fi
  echo "[OK] entitlements 注入验证通过 (no-sandbox / platform-application / TCC / keychain / container 全部就位)"
}

sign_copy_entitlements() {
  local app="$1"
  echo "[*] 注入 entitlements 到 $app"
  # TrollStore 不校验真实签名，但需要 ldid 注入权限 xml 以便 TrollStore 识别
  if command -v ldid >/dev/null 2>&1; then
    ldid -S"$ROOT/TrollAutoTouch/TrollAutoTouch.entitlements" "$app/TrollAutoTouch"
  else
    echo "[x] 未找到 ldid，无法注入 entitlements！"
    echo "    请安装: brew install ldid  (或从 TrollStore 官方仓库获取 ldid)"
    exit 1
  fi
  verify_entitlements "$app"
}

# ── 图标生成：把缺失的 PNG 同步补到 Assets.xcassets 并放到 .app 根目录 ──
# 同时保证 App Switcher 顶部图标（走 Assets.car 路径）也能渲染
prepare_icons() {
  local app="$1"
  local src="$ROOT/TrollAutoTouch_icon.png"
  local iconset="$ROOT/TrollAutoTouch/Assets.xcassets/AppIcon.appiconset"

  echo "[*] 准备 App 图标..."

  if command -v sips >/dev/null 2>&1; then
    # 1) 在 Assets.xcassets 里补齐缺尺寸 (40x40/29x29) — 否则 xcodebuild 编译出的
    #    Assets.car 不含这些图标，App Switcher 顶部图标就显示空。
    sips -z  80  80 "$src" --out "$iconset/AppIcon40x40@2x.png" >/dev/null 2>&1
    sips -z 120 120 "$src" --out "$iconset/AppIcon40x40@3x.png" >/dev/null 2>&1
    sips -z  58  58 "$src" --out "$iconset/AppIcon29x29@2x.png" >/dev/null 2>&1
    sips -z  87  87 "$src" --out "$iconset/AppIcon29x29@3x.png" >/dev/null 2>&1

    # 2) 在 .app 根目录生成所有 PNG (CFBundleIconFiles 路径也能找到)
    # 桌面图标 60x60pt
    sips -z 120 120 "$src" --out "$app/AppIcon60x60@2x.png" >/dev/null 2>&1
    sips -z 180 180 "$src" --out "$app/AppIcon60x60@3x.png" >/dev/null 2>&1
    # App Switcher / Spotlight 40x40pt
    sips -z  80  80 "$src" --out "$app/AppIcon40x40@2x.png" >/dev/null 2>&1
    sips -z 120 120 "$src" --out "$app/AppIcon40x40@3x.png" >/dev/null 2>&1
    # 设置 / 搜索 29x29pt
    sips -z  58  58 "$src" --out "$app/AppIcon29x29@2x.png" >/dev/null 2>&1
    sips -z  87  87 "$src" --out "$app/AppIcon29x29@3x.png" >/dev/null 2>&1
    # iPad 76x76pt
    sips -z  76  76 "$src" --out "$app/AppIcon76x76~ipad.png"    >/dev/null 2>&1
    sips -z 152 152 "$src" --out "$app/AppIcon76x76@2x~ipad.png" >/dev/null 2>&1
    # App Store 1024
    sips -z 1024 1024 "$src" --out "$app/icon-1024.png"          >/dev/null 2>&1
    echo "[*] 图标生成完成（sips）"
  else
    # 无 sips：回退到 Assets.xcassets 中的占位图标
    if ls "$iconset"/*.png 1>/dev/null 2>&1; then
      cp "$iconset"/*.png "$app/"
      echo "[*] 图标拷贝完成（Assets.xcassets 占位）"
    else
      echo "[!] 无可用图标"
    fi
  fi
}

# ── 根目录 main.lua 是唯一脚本事实来源: 构建前同步到 Resources/lua ──
# 打包进 bundle 的 lua/main.lua 由 AppDelegate 同步到设备 /var/mobile/touch/lua
sync_main_lua() {
  local src="$ROOT/main.lua"
  local dst="$ROOT/TrollAutoTouch/Resources/lua/Main.lua"
  [ -f "$src" ] || { echo "[x] 根目录 main.lua 不存在: $src"; exit 1; }
  cp "$src" "$dst"
  echo "[*] main.lua 已同步: 根目录 → Resources/lua/Main.lua ($(wc -c < "$dst") bytes)"
}

# ── 在 xcodebuild 之前先补齐 Assets.xcassets 里缺失的 PNG ──
# 必须在 xcodebuild 之前调用，否则 Assets.car 不会包含小尺寸图标
prepare_assets_xcassets() {
  local src="$ROOT/TrollAutoTouch_icon.png"
  local iconset="$ROOT/TrollAutoTouch/Assets.xcassets/AppIcon.appiconset"
  echo "[*] 准备 Assets.xcassets..."
  if command -v sips >/dev/null 2>&1; then
    [ -f "$iconset/AppIcon40x40@2x.png" ] || sips -z  80  80 "$src" --out "$iconset/AppIcon40x40@2x.png" >/dev/null 2>&1
    [ -f "$iconset/AppIcon40x40@3x.png" ] || sips -z 120 120 "$src" --out "$iconset/AppIcon40x40@3x.png" >/dev/null 2>&1
    [ -f "$iconset/AppIcon29x29@2x.png" ] || sips -z  58  58 "$src" --out "$iconset/AppIcon29x29@2x.png" >/dev/null 2>&1
    [ -f "$iconset/AppIcon29x29@3x.png" ] || sips -z  87  87 "$src" --out "$iconset/AppIcon29x29@3x.png" >/dev/null 2>&1
    echo "[*] Assets.xcassets PNG 补齐完成"
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
    sync_main_lua
    prepare_assets_xcassets
    xcodebuild -project "$ROOT/TrollAutoTouch.xcodeproj" \
      -scheme TrollAutoTouch \
      -configuration Release \
      -sdk iphoneos \
      ARCHS="arm64 arm64e" \
      ONLY_ACTIVE_ARCH=NO \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      CODE_SIGN_IDENTITY="" \
      -derivedDataPath "$BUILD_DIR/DerivedData" \
      build
    APP="$(find "$BUILD_DIR/DerivedData" -name 'TrollAutoTouch.app' -type d | head -1)"
    [ -z "$APP" ] && { echo "[x] 未找到编译产物 TrollAutoTouch.app"; exit 1; }
    rm -rf "$PAYLOAD"; mkdir -p "$PAYLOAD"
    cp -R "$APP" "$PAYLOAD/"

    # ── 网页资源 (noVNC 首页 + 脚本设置 UI): 整目录拷贝, 保留 www/ 结构 ──
    # (不走 xcodegen 打包, 避免 www/index.html 与 www/ui/*/index.html
    #  因 basename 相同在 Copy Bundle Resources 里冲突)
    cp -R "$ROOT/TrollAutoTouch/Resources/www" "$PAYLOAD/TrollAutoTouch.app/www"
    echo "[OK] www 网页资源已打包 (www/index.html noVNC + www/ui/* 脚本设置页)"

    # ── 注入式触摸服务: 编译 dylib + 打包 opainject 注入器 ──
    echo "[*] 编译触摸服务 dylib (TSInjectedTouchService)"
    # 注意: -target 构建不能搭配 -derivedDataPath (xcodebuild 限制),
    # 用 CONFIGURATION_BUILD_DIR 显式指定 dylib 输出目录。
    xcodebuild -project "$ROOT/TrollAutoTouch.xcodeproj" \
      -target TSInjectedTouchService \
      -configuration Release \
      -sdk iphoneos \
      ARCHS="arm64 arm64e" \
      ONLY_ACTIVE_ARCH=NO \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      CODE_SIGN_IDENTITY="" \
      CONFIGURATION_BUILD_DIR="$BUILD_DIR/dylib" \
      build
    DYLIB="$(find "$BUILD_DIR/dylib" "$BUILD_DIR/DerivedData" -name 'TSInjectedTouchService.dylib' -type f 2>/dev/null | head -1)"
    [ -z "$DYLIB" ] && { echo "[x] 未找到 TSInjectedTouchService.dylib"; exit 1; }
    mkdir -p "$PAYLOAD/TrollAutoTouch.app/bin"
    cp "$DYLIB" "$PAYLOAD/TrollAutoTouch.app/bin/TSInjectedTouchService.dylib"
    cp "$ROOT/TrollAutoTouch/Resources/bin/opainject" "$PAYLOAD/TrollAutoTouch.app/bin/opainject"
    chmod 755 "$PAYLOAD/TrollAutoTouch.app/bin/opainject"
    # opainject 需要 task_for_pid 等注入权限, 打包时用 ldid 预签名,
    # 否则 TrollStore 重签后这些 entitlement 不保证保留, 注入 SpringBoard 会失败
    if command -v ldid >/dev/null 2>&1; then
      ldid -S"$ROOT/TrollAutoTouch/Resources/injector.entitlements.xml" "$PAYLOAD/TrollAutoTouch.app/bin/opainject"
      echo "[OK] opainject 已注入注入器 entitlements (task_for_pid 等)"
    else
      echo "[!] 未找到 ldid, opainject 未预签名 (注入可能失败)"
    fi
    # 运行时重签工具链 + entitlements: app 用 ldid 在注入前重签 opainject/dylib,
    # 恢复 TrollStore 安装时被剥离的 entitlements (no-sandbox / task_for_pid-allow 等)。
    for T in ldid fastPathSign; do
      cp "$ROOT/TrollAutoTouch/Resources/bin/$T" "$PAYLOAD/TrollAutoTouch.app/bin/$T" 2>/dev/null && chmod 755 "$PAYLOAD/TrollAutoTouch.app/bin/$T"
    done
    cp "$ROOT/TrollAutoTouch/Resources/bin/ent2.xml" "$PAYLOAD/TrollAutoTouch.app/bin/ent2.xml" 2>/dev/null || true
    cp "$ROOT/TrollAutoTouch/Resources/opainject.entitlements.xml" "$PAYLOAD/TrollAutoTouch.app/bin/opainject.entitlements.xml" 2>/dev/null || true
    cp "$ROOT/TrollAutoTouch/Resources/injector.entitlements.xml" "$PAYLOAD/TrollAutoTouch.app/bin/injector.entitlements.xml" 2>/dev/null || true
    echo "[OK] 运行时重签工具链已部署到 bin/"
    echo "[OK] 触摸服务已打包: bin/TSInjectedTouchService.dylib + bin/opainject"

    prepare_icons "$PAYLOAD/TrollAutoTouch.app"
    sign_copy_entitlements "$PAYLOAD/TrollAutoTouch.app"

    # ── HUD 全局弹窗: 单 App 架构, 已并入主 App 进程内 ──
    # (TSHUDHost + SBSAccessibilityWindowHostingController, 见 TrollAutoTouch/HUD/)
    # 不再编译独立 HUDServices.app, tipa 只含 Payload/TrollAutoTouch.app,
    # 桌面只显示 TrollAutoTouch 一个图标。
    echo "[OK] HUD 宿主已随主 App 编译 (进程内, 无独立 app)"
    ;;
  payload)
    APP="${2:-}"
    [ -z "$APP" ] && { echo "用法: $0 payload path/to/TrollAutoTouch.app"; exit 1; }
    rm -rf "$PAYLOAD"; mkdir -p "$PAYLOAD"
    cp -R "$APP" "$PAYLOAD/"
    # 网页资源 (noVNC + 脚本设置 UI): 编译产物未含 www 时从仓库补拷
    if [ ! -d "$PAYLOAD/TrollAutoTouch.app/www" ]; then
      cp -R "$ROOT/TrollAutoTouch/Resources/www" "$PAYLOAD/TrollAutoTouch.app/www"
      echo "[OK] www 网页资源已打包 (www/index.html noVNC + www/ui/* 脚本设置页)"
    fi
    # 注入式触摸服务: opainject 从 Resources/bin 拷贝; dylib 若已在 build 产物则一并打包
    mkdir -p "$PAYLOAD/TrollAutoTouch.app/bin"
    cp "$ROOT/TrollAutoTouch/Resources/bin/opainject" "$PAYLOAD/TrollAutoTouch.app/bin/opainject"
    chmod 755 "$PAYLOAD/TrollAutoTouch.app/bin/opainject"
    if command -v ldid >/dev/null 2>&1; then
      ldid -S"$ROOT/TrollAutoTouch/Resources/injector.entitlements.xml" "$PAYLOAD/TrollAutoTouch.app/bin/opainject"
      echo "[OK] opainject 已注入注入器 entitlements"
    fi
    # 运行时重签工具链 + entitlements (同 xcode 子命令)
    for T in ldid fastPathSign; do
      cp "$ROOT/TrollAutoTouch/Resources/bin/$T" "$PAYLOAD/TrollAutoTouch.app/bin/$T" 2>/dev/null && chmod 755 "$PAYLOAD/TrollAutoTouch.app/bin/$T"
    done
    cp "$ROOT/TrollAutoTouch/Resources/bin/ent2.xml" "$PAYLOAD/TrollAutoTouch.app/bin/ent2.xml" 2>/dev/null || true
    cp "$ROOT/TrollAutoTouch/Resources/opainject.entitlements.xml" "$PAYLOAD/TrollAutoTouch.app/bin/opainject.entitlements.xml" 2>/dev/null || true
    cp "$ROOT/TrollAutoTouch/Resources/injector.entitlements.xml" "$PAYLOAD/TrollAutoTouch.app/bin/injector.entitlements.xml" 2>/dev/null || true
    DYLIB="$(find "$BUILD_DIR/DerivedData" -name 'TSInjectedTouchService.dylib' -type f 2>/dev/null | head -1)"
    if [ -n "$DYLIB" ]; then
      cp "$DYLIB" "$PAYLOAD/TrollAutoTouch.app/bin/TSInjectedTouchService.dylib"
      echo "[OK] 触摸服务 dylib 已打包 (bin/TSInjectedTouchService.dylib)"
    else
      echo "[!] 未找到 TSInjectedTouchService.dylib (跳过, 触摸注入将不可用)"
    fi
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
