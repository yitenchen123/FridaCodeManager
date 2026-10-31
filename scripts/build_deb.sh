#!/bin/sh
#
# build_deb.sh —— 在越狱设备上一键构建 FridaCodeManager 的 .deb
#
# 用法：
#   sh scripts/build_deb.sh            # rootless 越狱（/var/jb），默认
#   sh scripts/build_deb.sh roothide   # roothide 越狱
#   sh scripts/build_deb.sh clean      # 清理中间产物
#
# 脚本会依次检查依赖、补全 SDK/theos headers、调用 Makefile、校验产物。

set -e

JD_ROOT="/var/jb"
MODE="${1:-rootless}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_DIR/Product"
SDK_DIR="$REPO_DIR/SDK"
HEADERS_DIR="$REPO_DIR/Blueprint/FridaCodeManager.app/include"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

cd "$REPO_DIR"

if [ "$MODE" = "clean" ]; then
    yellow "==> 清理中间产物"
    rm -rf .package Product Blueprint/FridaCodeManager.app/swifty Essentials/lib/build
    green "已清理"
    exit 0
fi

case "$MODE" in
    rootless) TARGET="all";      JB_PATH="$JD_ROOT/" ;;
    roothide) TARGET="roothide"; JB_PATH="/" ;;
    *) red "未知模式: $MODE（可选 rootless / roothide / clean）"; exit 2 ;;
esac

# ---------- 1. 环境检查 ----------
green "==> [1/5] 检查构建环境"
MISSING=""
for tool in swiftc clang make ldid dpkg-deb git unzip ar; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        MISSING="$MISSING $tool"
    fi
done
if [ -n "$MISSING" ]; then
    red "缺少工具:$MISSING"
    echo "越狱设备上安装：apt install swift clang-14 ldid dpkg-dev git unzip"
    exit 1
fi

if [ "$MODE" = "rootless" ] && [ ! -d "$JD_ROOT" ]; then
    echo "提示：未发现 $JD_ROOT，说明这不是 rootless 越狱设备。"
    echo "      roothide 越狱请用: sh scripts/build_deb.sh roothide"
fi

# 所有依赖都是 arm64 iOS 二进制
if [ "$(uname -m)" != "arm64" ] && [ "$(uname -m)" != "aarch64" ]; then
    red "当前架构 $(uname -m) 不是 arm64；本脚本只能在 arm64 越狱设备（或 arm64 macOS）上运行。"
    exit 1
fi

# ---------- 2. SDK ----------
green "==> [2/5] 准备 iOS SDK"
if [ ! -d "$SDK_DIR" ]; then
    ZIP="$REPO_DIR/FCM/UI/TabBar/Settings/SDKHub/sdk/iOS15.6.zip"
    if [ ! -f "$ZIP" ]; then
        red "找不到 SDK 压缩包: $ZIP"
        echo "请先补全 FCM/UI/TabBar/Settings/SDKHub/sdk/ 目录（含 iOS15.6.zip）。"
        exit 1
    fi
    yellow "    解压 iOS15.6.zip ..."
    rm -rf "$REPO_DIR/.sdk_tmp"
    mkdir -p "$REPO_DIR/.sdk_tmp"
    unzip -q "$ZIP" -d "$REPO_DIR/.sdk_tmp"
    mv "$REPO_DIR/.sdk_tmp/iPhoneOS15.6.sdk" "$SDK_DIR"
    rm -rf "$REPO_DIR/.sdk_tmp"
    # iOS SDK 里 MobileContainerManager 在 PrivateFrameworks 下，需要挪到 Frameworks
    if [ -d "$SDK_DIR/System/Library/PrivateFrameworks/MobileContainerManager.framework" ] &&
       [ ! -d "$SDK_DIR/System/Library/Frameworks/MobileContainerManager.framework" ]; then
        mv "$SDK_DIR/System/Library/PrivateFrameworks/MobileContainerManager.framework" \
           "$SDK_DIR/System/Library/Frameworks/MobileContainerManager.framework"
    fi
fi
green "    SDK: $SDK_DIR"

# ---------- 3. theos headers ----------
green "==> [3/5] 准备 theos headers"
if [ ! -d "$HEADERS_DIR" ]; then
    yellow "    克隆 theos/headers（仅 header，体积很小）..."
    rm -rf "$REPO_DIR/.headers_tmp"
    git clone --depth 1 https://github.com/theos/headers.git "$REPO_DIR/.headers_tmp"
    mv "$REPO_DIR/.headers_tmp" "$HEADERS_DIR"
fi
green "    headers: $HEADERS_DIR"

# ---------- 4. 编译并打包 ----------
green "==> [4/5] 编译（make $TARGET）"
echo "    这可能需要几分钟，期间会输出 swiftc 的编译信息。"
mkdir -p "$OUT_DIR"
make "$TARGET"

# ---------- 5. 校验产物 ----------
green "==> [5/5] 校验产物"
DEB=$(ls -1 "$OUT_DIR"/*.deb 2>/dev/null | head -n 1)
if [ -z "$DEB" ]; then
    red "没找到 .deb 产物，请检查上面的编译输出。"
    exit 1
fi

echo
green "构建成功 ✔"
echo "  文件：$DEB"
echo "  大小：$(du -h "$DEB" | cut -f1)"
echo
echo "安装："
echo "  dpkg -i \"$DEB\"          # 或在 Sileo/Zebra 里打开该文件"
echo "  构建后建议执行 respring 让图标刷新。"
