#!/bin/bash
#
#  build.sh
#  无忧辅助 - 完整构建脚本
#
#  用法:
#    1. 在 macOS 上执行:  bash build.sh
#    2. 生成的 IPA 路径:  ./build/无忧辅助.ipa
#    3. 用 TrollStore 安装生成的 IPA
#
#  前提条件:
#    - macOS + Xcode Command Line Tools
#    - ldid (brew install ldid)
#    - 或使用 Theos 工具链
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_NAME="无忧辅助"
BUNDLE_ID="com.wuyou.helper"
BUILD_DIR="${SCRIPT_DIR}/build"
APP_DIR="${BUILD_DIR}/payload/${PROJECT_NAME}.app"
HELPER_SRC="${SCRIPT_DIR}/roothelper/main.c"
SWIFT_SRC="${SCRIPT_DIR}/无忧辅助"
ENTITLEMENTS="${SCRIPT_DIR}/entitlements.plist"

echo "============================================"
echo "  无忧辅助 IPA 构建脚本"
echo "============================================"
echo ""

# 清理
rm -rf "${BUILD_DIR}"
mkdir -p "${APP_DIR}"

# ========================================
# Step 1: 编译 roothelper (C -> arm64)
# ========================================
echo "[1/5] 编译 roothelper (纯 C → arm64)..."
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
if [ -z "$SDK_PATH" ]; then
    echo "❌ 未找到 iPhoneOS SDK，请确认 Xcode 已安装"
    exit 1
fi

clang -arch arm64 \
      -isysroot "${SDK_PATH}" \
      -mios-version-min=14.0 \
      -O2 \
      -o "${APP_DIR}/roothelper" \
      "${HELPER_SRC}"

echo "   ✅ roothelper 编译完成"

# 签名 helper
echo "   🔐 签名 roothelper..."
ldid -S"${ENTITLEMENTS}" "${APP_DIR}/roothelper" 2>/dev/null || {
    echo "   ⚠️  ldid 签名失败，尝试 codesign..."
    codesign -s - --entitlements "${ENTITLEMENTS}" "${APP_DIR}/roothelper" 2>/dev/null || {
        echo "   ⚠️  签名跳过（TrollStore 会处理签名）"
    }
}

# 签名主应用（如果存在）
if [ -f "${APP_DIR}/${PROJECT_NAME}" ]; then
    echo "   🔐 签名主应用..."
    ldid -S"${ENTITLEMENTS}" "${APP_DIR}/${PROJECT_NAME}" 2>/dev/null || {
        echo "   ⚠️  主应用签名失败，尝试 codesign..."
        codesign -s - --entitlements "${ENTITLEMENTS}" "${APP_DIR}/${PROJECT_NAME}" 2>/dev/null || {
            echo "   ⚠️  主应用签名跳过（TrollStore 会处理签名）"
        }
    }
fi

# ========================================
# Step 2: 编译 Swift (xcodebuild)
# ========================================
echo "[2/5] 编译 Swift 应用..."

# TODO: 需要你手动创建 Xcode 项目或用下面的方式编译
# 这里用 swiftc 直接编译（简化方式，适合无 Xcode 项目的场景）
#
# 推荐方式：手动创建 Xcode 项目后，替换为：
#   xcodebuild -project "${SCRIPT_DIR}/无忧辅助.xcodeproj" \
#              -scheme "无忧辅助" \
#              -configuration Release \
#              -sdk iphoneos \
#              -archivePath "${BUILD_DIR}/无忧辅助.xcarchive" \
#              archive
#   xcodebuild -exportArchive -archivePath "${BUILD_DIR}/无忧辅助.xcarchive" \
#              -exportPath "${BUILD_DIR}" \
#              -exportOptionsPlist exportOptions.plist

echo ""
echo "   ⚠️  Swift 编译需要 Xcode 项目"
echo "   → 请先创建 Xcode 项目并将所有 Swift 文件加入项目"
echo "   → 然后手动运行 xcodebuild，或把 .app 产物放到 build/payload/ 下"
echo ""

# ========================================
# Step 3: 复制资源文件
# ========================================
echo "[3/5] 复制资源文件..."

# 复制 entitlements 作为参考
cp "${ENTITLEMENTS}" "${BUILD_DIR}/"

# Info.plist (如果有的话)
if [ -f "${SWIFT_SRC}/Info.plist" ]; then
    cp "${SWIFT_SRC}/Info.plist" "${APP_DIR}/"
fi

echo "   ✅ 资源文件复制完成"

# ========================================
# Step 4: 签名 App (TrollStore 方式)
# ========================================
echo "[4/5] TrollStore 签名处理..."

# TrollStore 签名说明:
#   - 用 ldid 对 .app 进行伪签名
#   - 或用 TrollStore 安装时自动签名
#
# 手动签名：
#   ldid -S${ENTITLEMENTS} ${APP_DIR}/${PROJECT_NAME}
#   ldid -S${ENTITLEMENTS} ${APP_DIR}/roothelper

echo "   ℹ️  TrollStore 会在安装时自动处理签名"
echo "   如需手动签名："
echo "     ldid -S${ENTITLEMENTS} ${APP_DIR}/${PROJECT_NAME}"

# ========================================
# Step 5: 打包 IPA
# ========================================
echo "[5/5] 打包 IPA..."

cd "${BUILD_DIR}"
zip -qr "${PROJECT_NAME}.ipa" Payload/
cd "${SCRIPT_DIR}"

echo "   ✅ IPA 打包完成"
echo ""

# ========================================
# 完成
# ========================================
echo "============================================"
echo "  构建完成！"
echo "============================================"
echo ""
echo "  IPA 文件: ${BUILD_DIR}/${PROJECT_NAME}.ipa"
echo ""
echo "安装步骤:"
echo "  1. 将 ${PROJECT_NAME}.ipa 传到手机"
echo "  2. 用 TrollStore 打开并安装"
echo "  3. 打开「无忧辅助」App"
echo "  4. 点击「重启手机」或「注销桌面」"
echo ""
echo "⚠️  注意: 此应用需要 TrollStore 环境才能获得 root 权限"
echo "============================================"
