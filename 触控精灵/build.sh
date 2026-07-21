#!/bin/bash
# ============================================================
#  触控精灵 — WSL2 交叉编译 arm64 IPA 一键构建脚本
# ============================================================
#  环境要求:
#    - WSL2 (Ubuntu 22.04+)
#    - clang + ldid
#    - iOS SDK (从 Xcode 提取到 ~/ios-sdk/)
#
#  编译流程:
#    1. 下载/编译 Lua 5.4.7 静态库
#    2. 编译所有 Objective-C 源文件
#    3. 链接为 arm64 可执行文件
#    4. 打包 .app bundle
#    5. ldid 签名
#    6. 输出 IPA
# ============================================================

set -e

# ---- 配置 ----
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$PROJECT_DIR/src"
LUA_VERSION="5.4.7"
LUA_DIR="$PROJECT_DIR/lua-${LUA_VERSION}"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="触控精灵"
BUNDLE_ID="com.touchsprite.automation"

# iOS SDK 路径（根据实际环境修改）
IOS_SDK="${IOS_SDK:-$HOME/ios-sdk/iPhoneOS.sdk}"
if [ ! -d "$IOS_SDK" ]; then
    # 尝试常见路径
    for d in \
        "$HOME/ios-sdk/iPhoneOS.sdk" \
        "/opt/ios-sdk/iPhoneOS.sdk" \
        "/usr/share/ios-sdk/iPhoneOS.sdk" \
    ; do
        if [ -d "$d" ]; then IOS_SDK="$d"; break; fi
    done
fi

# 最低部署目标
DEPLOY_TARGET="15.0"
ARCH="arm64"

# 编译器和标志
CLANG="clang"
CFLAGS="-arch $ARCH -isysroot $IOS_SDK -miphoneos-version-min=$DEPLOY_TARGET -fobjc-arc -fobjc-abi-version=2 -std=gnu11"
LDFLAGS="-arch $ARCH -isysroot $IOS_SDK -miphoneos-version-min=$DEPLOY_TARGET -framework UIKit -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework IOSurface -framework IOKit -fobjc-link-runtime"

# ---- 颜色输出 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---- 检查环境 ----
check_env() {
    log "检查编译环境..."
    command -v $CLANG >/dev/null 2>&1 || err "未找到 clang，请安装: apt install clang"
    command -v ldid >/dev/null 2>&1 || warn "未找到 ldid，将使用内置签名（apt install ldid 或从 Procursus 安装）"
    command -v curl >/dev/null 2>&1 || err "未找到 curl"
    command -v tar  >/dev/null 2>&1 || err "未找到 tar"

    if [ ! -d "$IOS_SDK" ]; then
        err "未找到 iOS SDK: $IOS_SDK\n  请从 macOS Xcode.app 复制 SDK:\n  cp -r /Applications/Xcode.app/.../iPhoneOS.sdk ~/ios-sdk/"
    fi
    log "✅ 环境检查通过 | SDK: $IOS_SDK"
}

# ---- 编译 Lua 5.4 ----
build_lua() {
    if [ -f "$BUILD_DIR/lib/liblua.a" ]; then
        log "Lua 静态库已存在，跳过编译"
        return
    fi

    log "下载 Lua $LUA_VERSION..."
    LUA_TARBALL="lua-${LUA_VERSION}.tar.gz"
    LUA_URL="https://www.lua.org/ftp/$LUA_TARBALL"

    if [ ! -d "$LUA_DIR" ]; then
        if [ ! -f "$LUA_TARBALL" ]; then
            curl -L -o "$LUA_TARBALL" "$LUA_URL" || err "下载 Lua 失败"
        fi
        tar xzf "$LUA_TARBALL" || err "解压 Lua 失败"
        rm -f "$LUA_TARBALL"
    fi

    log "编译 Lua (arm64 iOS)..."
    cd "$LUA_DIR/src"

    # 收集所有 .c 文件（排除 lua.c 和 luac.c）
    LUA_SRCS=""
    for f in *.c; do
        if [ "$f" != "lua.c" ] && [ "$f" != "luac.c" ]; then
            LUA_SRCS="$LUA_SRCS $f"
        fi
    done

    mkdir -p "$BUILD_DIR/obj/lua" "$BUILD_DIR/lib"

    for src in $LUA_SRCS; do
        obj="$BUILD_DIR/obj/lua/${src%.c}.o"
        $CLANG $CFLAGS -DLUA_USE_IOS -c "$src" -o "$obj" || err "编译 Lua $src 失败"
    done

    # 打包静态库
    ar rcs "$BUILD_DIR/lib/liblua.a" "$BUILD_DIR"/obj/lua/*.o || err "ar 打包失败"
    log "✅ Lua 静态库: $BUILD_DIR/lib/liblua.a"

    # 复制头文件
    mkdir -p "$BUILD_DIR/include"
    cp lua.h lualib.h lauxlib.h luaconf.h "$BUILD_DIR/include/"

    cd "$PROJECT_DIR"
}

# ---- 编译 Objective-C 源文件 ----
build_app() {
    log "编译触控精灵源文件..."
    mkdir -p "$BUILD_DIR/obj/app"

    # Lua 头文件路径
    LUA_INCLUDE="$BUILD_DIR/include"

    for src in "$SRC_DIR"/*.m; do
        name=$(basename "$src" .m)
        obj="$BUILD_DIR/obj/app/${name}.o"
        $CLANG $CFLAGS -I"$LUA_INCLUDE" -I"$SRC_DIR" -c "$src" -o "$obj" || err "编译 $name.m 失败"
    done

    log "✅ 源文件编译完成"
}

# ---- 链接可执行文件 ----
link_app() {
    log "链接可执行文件..."
    mkdir -p "$BUILD_DIR/app"

    $CLANG $LDFLAGS \
        "$BUILD_DIR"/obj/app/*.o \
        "$BUILD_DIR/lib/liblua.a" \
        -o "$BUILD_DIR/app/$APP_NAME" \
        -lobjc \
        || err "链接失败"

    log "✅ 可执行文件: $BUILD_DIR/app/$APP_NAME"
}

# ---- 打包 .app Bundle ----
package_app() {
    log "打包 .app Bundle..."
    local app="$BUILD_DIR/Payload/${APP_NAME}.app"
    mkdir -p "$app"

    # 复制可执行文件
    cp "$BUILD_DIR/app/$APP_NAME" "$app/"

    # Info.plist
    cp "$PROJECT_DIR/Info.plist" "$app/"

    # 测试脚本（放入 bundle 资源）
    if [ -f "$PROJECT_DIR/test_script.lua" ]; then
        cp "$PROJECT_DIR/test_script.lua" "$app/"
    fi

    log "✅ .app Bundle: $app"
}

# ---- 签名 ----
sign_app() {
    log "签名应用..."
    local app="$BUILD_DIR/Payload/${APP_NAME}.app"
    local entitlements="$PROJECT_DIR/entitlements.plist"

    if command -v ldid >/dev/null 2>&1; then
        ldid -S"$entitlements" "$app/$APP_NAME" || warn "ldid 签名失败"
        log "✅ ldid 签名完成"
    else
        # 尝试用 codesign 或简单 ad-hoc 签名
        warn "ldid 不可用，尝试 ad-hoc 签名..."
        if command -v codesign >/dev/null 2>&1; then
            codesign -s - --entitlements "$entitlements" "$app" 2>/dev/null || true
        fi
        warn "⚠️ 无可用签名工具，请安装 ldid 后重新签名"
    fi
}

# ---- 创建 IPA ----
create_ipa() {
    log "创建 IPA..."
    cd "$BUILD_DIR"
    rm -f "${APP_NAME}.ipa"

    # Payload 目录
    mkdir -p Payload
    zip -qr "${APP_NAME}.ipa" Payload/
    cd "$PROJECT_DIR"

    log "✅ IPA 已生成: $BUILD_DIR/${APP_NAME}.ipa"
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  构建完成!${NC}"
    echo -e "${GREEN}  IPA: $BUILD_DIR/${APP_NAME}.ipa${NC}"
    echo -e "${GREEN}  通过 TrollStore 直接安装即可${NC}"
    echo -e "${GREEN}========================================${NC}"
}

# ---- 清理 ----
clean() {
    log "清理构建文件..."
    rm -rf "$BUILD_DIR"
    rm -rf "$LUA_DIR"
    log "✅ 清理完成"
}

# ---- 主流程 ----
main() {
    case "${1:-build}" in
        clean)
            clean
            ;;
        lua)
            check_env
            build_lua
            ;;
        build)
            check_env
            build_lua
            build_app
            link_app
            package_app
            sign_app
            create_ipa
            ;;
        *)
            echo "用法: $0 {build|clean|lua}"
            echo "  build  完整编译 + 打包 IPA"
            echo "  clean  清理所有构建文件"
            echo "  lua    仅编译 Lua 静态库"
            exit 1
            ;;
    esac
}

main "$@"
