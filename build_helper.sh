#!/bin/bash
#
#  build_helper.sh
#  单独编译 roothelper 二进制（纯 C + kfd，链接 IOKit/CoreFoundation）
#
#  在 macOS 上执行:
#    bash build_helper.sh
#
#  输出: roothelper/roothelper (arm64 Mach-O)
#

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER_DIR="${SCRIPT_DIR}/roothelper"
HELPER_OUT="${HELPER_DIR}/roothelper"

echo "编译 roothelper (kfd + offsets + main)..."
SDK=$(xcrun --sdk iphoneos --show-sdk-path)

clang -arch arm64 \
      -isysroot "$SDK" \
      -mios-version-min=14.0 \
      -O2 \
      -o "$HELPER_OUT" \
      "${HELPER_DIR}/main.c" \
      "${HELPER_DIR}/kfd.c" \
      "${HELPER_DIR}/offsets.c" \
      -framework IOKit \
      -framework CoreFoundation

echo "✅ roothelper 编译完成: $HELPER_OUT"
file "$HELPER_OUT"

echo ""
echo "签名 (TrollStore 安装时会自动处理):"
echo "  ldid -S${SCRIPT_DIR}/helper.entitlements $HELPER_OUT"
echo ""
echo "已完成！"
