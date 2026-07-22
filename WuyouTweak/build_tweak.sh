#!/bin/bash
#
#  build_tweak.sh — WuyouTweak Dylib 构建脚本
#
#  用法:
#    bash build_tweak.sh          # 编译生成 dylib
#    bash build_tweak.sh inject   # 编译并注入到目标 IPA
#    bash build_tweak.sh clean    # 清理
#
#  前提条件:
#    - macOS + Xcode Command Line Tools
#    - Theos 已安装 (https://theos.dev/)
#    - ldid (brew install ldid)
#    - yololib (用于 Mach-O 注入)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TWEAK_NAME="WuyouTweak"
BUILD_DIR="${SCRIPT_DIR}/build"
DYLIB_NAME="lib${TWEAK_NAME}.dylib"

if [ "$1" = "clean" ]; then
    echo "[Clean] 清理构建产物..."
    rm -rf "${BUILD_DIR}"
    rm -rf "${SCRIPT_DIR}/.theos"
    echo "[Clean] 完成"
    exit 0
fi

echo "============================================"
echo "  WuyouTweak Dylib 构建脚本"
echo "============================================"
echo ""

if [ ! -d "${THEOS}" ]; then
    echo "❌ Theos 未安装或 THEOS 环境变量未设置"
    echo "   请安装 Theos: https://theos.dev/docs/installation"
    exit 1
fi

# Step 1: 使用 Theos 编译
echo "[1/3] 使用 Theos 编译 Tweak..."

cd "${SCRIPT_DIR}"

make clean
make package FINALPACKAGE=1

DYLIB_SRC="${SCRIPT_DIR}/.theos/obj/debug/${DYLIB_NAME}"
if [ ! -f "${DYLIB_SRC}" ]; then
    DYLIB_SRC="${SCRIPT_DIR}/.theos/obj/release/${DYLIB_NAME}"
fi

if [ ! -f "${DYLIB_SRC}" ]; then
    echo "❌ 未找到编译产物: ${DYLIB_NAME}"
    exit 1
fi

mkdir -p "${BUILD_DIR}"
cp "${DYLIB_SRC}" "${BUILD_DIR}/"
echo "   ✅ 编译完成: ${BUILD_DIR}/${DYLIB_NAME}"

# Step 2: 签名 dylib
echo "[2/3] 使用 ldid 签名 dylib..."
ldid -S "${BUILD_DIR}/${DYLIB_NAME}"
echo "   ✅ 签名完成"

# Step 3: 注入到目标 App (可选)
if [ "$1" = "inject" ]; then
    echo "[3/3] 注入到目标 App..."
    
    read -p "请输入目标 IPA 文件路径: " TARGET_IPA
    if [ ! -f "${TARGET_IPA}" ]; then
        echo "❌ 未找到目标 IPA: ${TARGET_IPA}"
        exit 1
    fi
    
    TEMP_DIR=$(mktemp -d)
    echo "   解压 IPA 到临时目录..."
    unzip -q "${TARGET_IPA}" -d "${TEMP_DIR}"
    
    APP_DIR=$(find "${TEMP_DIR}/Payload" -name "*.app" -type d | head -n1)
    if [ -z "${APP_DIR}" ]; then
        echo "❌ 未找到 .app 目录"
        rm -rf "${TEMP_DIR}"
        exit 1
    fi
    
    APP_BINARY=$(basename "${APP_DIR}" .app)
    APP_BINARY_PATH="${APP_DIR}/${APP_BINARY}"
    
    echo "   注入 dylib 到: ${APP_BINARY_PATH}"
    yololib "${APP_BINARY_PATH}" "@executable_path/${DYLIB_NAME}"
    
    echo "   复制 dylib 到 App 目录..."
    cp "${BUILD_DIR}/${DYLIB_NAME}" "${APP_DIR}/"
    
    echo "   重新打包 IPA..."
    cd "${TEMP_DIR}"
    zip -qr "${TEMP_DIR}/patched.ipa" Payload/
    cd "${SCRIPT_DIR}"
    
    PATCHED_IPA="${TARGET_IPA%.ipa}_patched.ipa"
    mv "${TEMP_DIR}/patched.ipa" "${PATCHED_IPA}"
    
    rm -rf "${TEMP_DIR}"
    echo "   ✅ 注入完成: ${PATCHED_IPA}"
else
    echo "[3/3] 手动注入步骤:"
    echo ""
    echo "   1. 将 ${DYLIB_NAME} 复制到目标 App 的 .app 目录"
    echo "   2. 使用 yololib 注入: yololib AppBinary @executable_path/${DYLIB_NAME}"
    echo "   3. 使用 ldid 重新签名: ldid -S AppBinary"
    echo "   4. 重新打包 IPA 并通过 TrollStore 安装"
fi

echo ""
echo "============================================"
echo "  构建成功！"
echo "============================================"
echo ""
echo "  Dylib 文件: ${BUILD_DIR}/${DYLIB_NAME}"
echo "  注入路径: @executable_path/${DYLIB_NAME}"
echo ""
echo "⚠️  注意: 目标 App 必须通过 TrollStore 安装"
echo "         以获取 no-sandbox 权限"
echo "============================================"