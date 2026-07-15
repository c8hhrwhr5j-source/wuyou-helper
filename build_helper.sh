#!/bin/bash
#
#  build_helper.sh
#  单独编译 roothelper 二进制
#
#  在 macOS 上执行:
#    bash build_helper.sh
#
#  输出: roothelper/roothelper (arm64 Mach-O)
#

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER_SRC="${SCRIPT_DIR}/roothelper/main.c"
HELPER_OUT="${SCRIPT_DIR}/roothelper/roothelper"

echo "编译 roothelper..."
SDK=$(xcrun --sdk iphoneos --show-sdk-path)

clang -arch arm64 \
      -isysroot "$SDK" \
      -mios-version-min=14.0 \
      -O2 \
      -o "$HELPER_OUT" \
      "$HELPER_SRC"

echo "✅ roothelper 编译完成: $HELPER_OUT"
file "$HELPER_OUT"

# 可选: 签名
echo ""
echo "签名 (TrollStore 安装时会自动处理):"
echo "  ldid -S${SCRIPT_DIR}/entitlements.plist $HELPER_OUT"
echo ""
echo "已完成！"
