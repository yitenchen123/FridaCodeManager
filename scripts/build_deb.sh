#!/bin/sh
#
# build_deb.sh —— 在越狱 iPhone/iPad 上一键构建 FridaCodeManager 的 .deb
#
# 用法（在仓库根目录执行）：
#   sh scripts/build_deb.sh              # 自动识别 rootless / roothide
#   sh scripts/build_deb.sh rootless     # 强制 rootless（/var/jb）
#   sh scripts/build_deb.sh roothide     # 强制 roothide
#   sh scripts/build_deb.sh check        # 只做环境检查，不编译
#   sh scripts/build_deb.sh clean        # 清理中间产物
#
# 说明：本包里的 Swift 代码只能由 iOS 上的 swiftc 编译，
#       请在越狱设备上用终端（NewTerm/iSH 越狱版/SSH）运行本脚本。

set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-auto}"
OUT_DIR="$REPO_DIR/Product"
SDK_DIR="$REPO_DIR/SDK"
HEADERS_DIR="$REPO_DIR/Blueprint/FridaCodeManager.app/include"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
die()    { red "错误：$*"; exit 1; }

cd "$REPO_DIR"

# ---------- 0. 基本子命令 ----------
case "$MODE" in
    clean)
        yellow "==> 清理中间产物"
        rm -rf .package Product Blueprint/FridaCodeManager.app/swifty \
               Essentials/lib/build Essentials/libfcm/tmp tmp
        green "已清理"
        exit 0
        ;;
esac

# ---------- 1. 平台检查 ----------
green "==> [1/6] 检查平台"
OS_NAME="$(uname -s)"
if [ "$OS_NAME" != "Darwin" ]; then
    red "当前系统是 $OS_NAME，不是 iOS/Darwin。"
    echo "  本脚本必须在越狱设备（或 macOS）上运行；"
    echo "  Linux 无法编译 iOS 二进制（Swift 不支持交叉编译到 iOS）。"
    exit 1
fi
ARCH="$(uname -m)"
case "$ARCH" in
    arm64|aarch64) : ;;
    *) die "当前架构 $ARCH 不是 arm64" ;;
esac
green "    平台: $OS_NAME / $ARCH"

# ---------- 2. 识别越狱类型 ----------
green "==> [2/6] 识别越狱类型"
if [ "$MODE" = "auto" ]; then
    if [ -x /var/jb/usr/bin/dpkg ] || [ -d /var/jb/usr/lib ]; then
        MODE="rootless"
    else
        MODE="roothide"
    fi
    green "    自动识别为: $MODE"
fi

case "$MODE" in
    rootless) PBROOT="/var/jb"; MK_TARGET="all";      ARCH_DEB="iphoneos-arm64"  ;;
    roothide) PBROOT="";        MK_TARGET="roothide"; ARCH_DEB="iphoneos-arm64e" ;;
    check)    PBROOT="";        MK_TARGET=""          ;;
    *) die "未知模式 '$MODE'（可选 rootless / roothide / auto / check / clean）" ;;
esac

# ---------- 3. 工具链检查 ----------
green "==> [3/6] 检查工具链"
MISSING=""
for tool in swiftc clang make ldid dpkg-deb git unzip ar; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        # 越狱前缀路径兜底
        if [ -n "$PBROOT" ] && [ -x "$PBROOT/usr/bin/$tool" ]; then
            PATH="$PBROOT/usr/bin:$PATH"; export PATH
        else
            MISSING="$MISSING $tool"
        fi
    fi
done

# uuid：Essentials/libfcm/Makefile 用它给 .o 命名
if ! command -v uuid >/dev/null 2>&1; then
    yellow "    缺少 uuid 命令，创建替代实现"
    if command -v uuidgen >/dev/null 2>&1; then
        mkdir -p "$REPO_DIR/.buildbin"
        printf '#!/bin/sh\nexec uuidgen\n' > "$REPO_DIR/.buildbin/uuid"
        chmod +x "$REPO_DIR/.buildbin/uuid"
        PATH="$REPO_DIR/.buildbin:$PATH"; export PATH
    else
        MISSING="$MISSING uuid"
    fi
fi

if [ -n "$MISSING" ]; then
    red "缺少工具:$MISSING"
    echo
    echo "  安装命令（与越狱类型对应）："
    if [ "$MODE" = "rootless" ]; then
        echo "    apt install swift clang-14 ldid dpkg-dev git unzip zip"
    else
        echo "    apt install swift clang-14 ldid dpkg-dev git unzip zip"
    fi
    echo
    echo "  说明：swift 来自 Chariz/Havoc 源的 Swift 5.x 工具链，需要 iOS 15+ 越狱环境。"
    exit 1
fi
green "    工具链齐全"

if [ "$MODE" = "check" ]; then
    green "检查完成（check 模式，不编译）"
    exit 0
fi

# ---------- 4. 准备 SDK 与 headers ----------
green "==> [4/6] 准备 SDK 与 theos headers"
if [ ! -d "$SDK_DIR" ]; then
    ZIP="$REPO_DIR/FCM/UI/TabBar/Settings/SDKHub/sdk/iOS15.6.zip"
    [ -f "$ZIP" ] || die "缺少 SDK 压缩包: $ZIP
  请先补全该目录（iOS15.6.zip），或把已有 SDK 放到 $SDK_DIR"
    yellow "    解压 iOS15.6.zip（约 36MB，需要一点时间）"
    rm -rf "$REPO_DIR/.sdk_tmp"; mkdir -p "$REPO_DIR/.sdk_tmp"
    unzip -q "$ZIP" -d "$REPO_DIR/.sdk_tmp"
    mv "$REPO_DIR/.sdk_tmp/iPhoneOS15.6.sdk" "$SDK_DIR"
    rm -rf "$REPO_DIR/.sdk_tmp"
    # iOS SDK 把 MobileContainerManager 放在 PrivateFrameworks 下，链接时需要移动到 Frameworks
    if [ -d "$SDK_DIR/System/Library/PrivateFrameworks/MobileContainerManager.framework" ] &&
       [ ! -d "$SDK_DIR/System/Library/Frameworks/MobileContainerManager.framework" ]; then
        mv "$SDK_DIR/System/Library/PrivateFrameworks/MobileContainerManager.framework" \
           "$SDK_DIR/System/Library/Frameworks/MobileContainerManager.framework"
    fi
fi
green "    SDK: $SDK_DIR"

if [ ! -d "$HEADERS_DIR" ]; then
    yellow "    克隆 theos/headers"
    rm -rf "$REPO_DIR/.headers_tmp"
    git clone --depth 1 https://github.com/theos/headers.git "$REPO_DIR/.headers_tmp"
    mv "$REPO_DIR/.headers_tmp" "$HEADERS_DIR"
fi
green "    headers: $HEADERS_DIR"

# ---------- 5. 编译 ----------
green "==> [5/6] 编译（make $MK_TARGET）"
echo "    首次编译可能需要 5–15 分钟。"
mkdir -p "$OUT_DIR"

# Essentials/Makefile 把 SHELL 写死为 /var/jb/bin/bash，
# roothide 环境下该路径不存在，用命令行变量覆盖。
if [ -n "$PBROOT" ] && [ -x "$PBROOT/bin/bash" ]; then
    MK_SHELL="$PBROOT/bin/bash"
elif [ -x /bin/bash ]; then
    MK_SHELL="/bin/bash"
elif [ -x /var/jb/bin/bash ]; then
    MK_SHELL="/var/jb/bin/bash"
else
    MK_SHELL="/bin/sh"
fi
green "    使用 SHELL=$MK_SHELL"

make "$MK_TARGET" SHELL="$MK_SHELL"

# ---------- 6. 校验 ----------
green "==> [6/6] 校验产物"
DEB="$(ls -1 "$OUT_DIR"/*.deb 2>/dev/null | head -n 1)"
[ -n "$DEB" ] || die "没有生成 .deb，请检查上面的编译输出"

echo
green "构建成功 ✔"
echo "  文件：$DEB"
echo "  大小：$(du -h "$DEB" | cut -f1)"
echo "  架构：$ARCH_DEB"
echo
echo "  安装：dpkg -i \"$DEB\""
echo "  或在 Sileo / Zebra 中打开该文件安装，装完 respring 一次。"
