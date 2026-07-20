#!/bin/bash
#
#  build.sh — 无忧辅助 完整构建脚本 (参考 TrollServer)
#
#  用法:
#    bash build.sh          # 构建 Release IPA
#    bash build.sh debug    # 构建 Debug IPA
#    bash build.sh clean    # 清理构建产物
#
#  前提条件:
#    - macOS + Xcode Command Line Tools
#    - ldid  (brew install ldid)
#    - xcodegen (brew install xcodegen) — 用于生成 Xcode 项目
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_NAME="无忧辅助"
BUNDLE_ID="com.wuyou.helper"
BUILD_DIR="${SCRIPT_DIR}/build"
PAYLOAD_DIR="${BUILD_DIR}/Payload"
APP_DIR="${PAYLOAD_DIR}/${PROJECT_NAME}.app"
SRC_DIR="${SCRIPT_DIR}/无忧辅助"
ENTITLEMENTS="${SCRIPT_DIR}/entitlements.plist"

CONFIGURATION="Release"

if [ "$1" = "debug" ]; then CONFIGURATION="Debug"; fi
if [ "$1" = "clean" ]; then
    echo "[Clean] 清理构建产物..."
    rm -rf "${BUILD_DIR}" "${SCRIPT_DIR}/DerivedData"
    echo "[Clean] 完成"
    exit 0
fi

echo "============================================"
echo "  无忧辅助 IPA 构建脚本"
echo "  配置: ${CONFIGURATION}"
echo "============================================"
echo ""

# 清理
rm -rf "${BUILD_DIR}"
mkdir -p "${APP_DIR}"

# ========================================
# Step 1: 生成 Xcode 项目 (如需要)
# ========================================
if [ -f "${SCRIPT_DIR}/project.yml" ]; then
    if command -v xcodegen &> /dev/null; then
        echo "[1/5] 生成 Xcode 项目..."
        cd "${SCRIPT_DIR}"
        xcodegen generate || true
    else
        echo "⚠️  xcodegen 未安装，跳过项目生成"
    fi
fi

# ========================================
# Step 2: xcodebuild 构建
# ========================================
echo "[2/5] xcodebuild 构建 (${CONFIGURATION})..."

if [ -f "${SCRIPT_DIR}/${PROJECT_NAME}.xcodeproj/project.pbxproj" ]; then
    xcodebuild \
        -project "${SCRIPT_DIR}/${PROJECT_NAME}.xcodeproj" \
        -scheme "${PROJECT_NAME}" \
        -configuration "${CONFIGURATION}" \
        -sdk iphoneos \
        -derivedDataPath "${SCRIPT_DIR}/DerivedData" \
        build

    # 找到构建产物
    BUILT_APP="${SCRIPT_DIR}/DerivedData/Build/Products/${CONFIGURATION}-iphoneos/${PROJECT_NAME}.app"
    if [ ! -d "${BUILT_APP}" ]; then
        BUILT_APP="$(find "${SCRIPT_DIR}/DerivedData" -name "${PROJECT_NAME}.app" -type d | head -n1)"
    fi

    if [ -d "${BUILT_APP}" ]; then
        cp -R "${BUILT_APP}/" "${APP_DIR}/"
        echo "   ✅ 复制构建产物: ${BUILT_APP}"
    else
        echo "❌ 未找到构建产物 .app"
        exit 1
    fi
else
    echo "❌ 未找到 Xcode 项目，请先运行: xcodegen generate"
    exit 1
fi

# ========================================
# Step 3: 编译 roothelper
# ========================================
echo "[3/5] 编译 roothelper (kfd + offsets + main)..."

SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
HELPER_DIR="${SCRIPT_DIR}/roothelper"
HELPER_DST="${APP_DIR}/roothelper"

clang -arch arm64 \
      -isysroot "${SDK_PATH}" \
      -mios-version-min=14.0 \
      -O2 \
      -o "${HELPER_DST}" \
      "${HELPER_DIR}/main.c" \
      "${HELPER_DIR}/kfd.c" \
      "${HELPER_DIR}/offsets.c" \
      -framework IOKit \
      -framework CoreFoundation

chmod +x "${HELPER_DST}"
echo "   ✅ roothelper 编译完成"

# ========================================
# Step 4: 注入 entitlements (关键步骤！)
# ========================================
echo "[4/5] 注入 entitlements..."

APP_BINARY="${APP_DIR}/${PROJECT_NAME}"

if [ ! -f "${ENTITLEMENTS}" ]; then
    echo "❌ 未找到 entitlements 文件: ${ENTITLEMENTS}"
    exit 1
fi

# 验证应用二进制存在
if [ ! -f "${APP_BINARY}" ]; then
    echo "❌ 找不到应用二进制: ${APP_BINARY}"
    echo "   目录内容:"
    ls -la "${APP_DIR}/"
    exit 1
fi

if command -v ldid &> /dev/null; then
    # 注入主应用 entitlements
    echo "   🔏 注入主应用 entitlements..."
    if ldid -S"${ENTITLEMENTS}" "${APP_BINARY}"; then
        echo "   ✅ 主应用 entitlements 已注入"
    else
        echo "   ⚠️  主应用 ldid 注入失败"
    fi

    # 验证 persona-mgmt 是否注入成功
    echo "   🔍 验证 entitlements..."
    if ldid -e "${APP_BINARY}" 2>/dev/null | grep -q "persona-mgmt"; then
        echo "   ✅ persona-mgmt 已确认"
    else
        echo "   ⚠️  persona-mgmt 未找到，可能注入失败！"
    fi

    # 注入 roothelper entitlements
    echo "   🔏 注入 roothelper entitlements..."
    if ldid -S"${ENTITLEMENTS}" "${HELPER_DST}"; then
        echo "   ✅ roothelper entitlements 已注入"
    else
        echo "   ⚠️  roothelper ldid 注入失败"
    fi
else
    echo "❌ 未找到 ldid，请安装: brew install ldid"
    exit 1
fi

# ========================================
# Step 5: 打包 IPA
# ========================================
echo "[5/5] 打包 IPA..."

# 写入 PkgInfo
echo "APPL????" > "${APP_DIR}/PkgInfo"

cd "${BUILD_DIR}"
zip -qr "${PROJECT_NAME}.ipa" Payload/
cd "${SCRIPT_DIR}"

IPA_SIZE=$(du -h "${BUILD_DIR}/${PROJECT_NAME}.ipa" | cut -f1)

echo ""
echo "============================================"
echo "  构建成功！"
echo "============================================"
echo ""
echo "  IPA 文件: ${BUILD_DIR}/${PROJECT_NAME}.ipa"
echo "  大小:     ${IPA_SIZE}"
echo "  Bundle:   ${BUNDLE_ID}"
echo ""
echo "  安装步骤:"
echo "    1. 将 IPA 传到手机"
echo "    2. 用 TrollStore 安装"
echo "    3. 安装后查看元数据，确认沙盒已关闭"
echo ""
echo "⚠️  注意: 此应用需要 TrollStore 环境"
echo "============================================"
