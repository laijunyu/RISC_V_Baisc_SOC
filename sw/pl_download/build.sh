#!/bin/sh
# build.sh - 编译 AXI UART Lite 下载工具
#
# 用法（WSL / Linux 里，改内核源码树需要 root）：
#   ./build.sh                                              # 只编用户态 pl_dl
#   sudo KDIR=/root/kernel-build/linux-6.18.39 ./build.sh    # 同时编 ko
#   sudo KDIR=... ZCONFIG=/path/to/config-zynq.txt ./build.sh  # 指定配置
#
# 产物：
#   pl_dl            ARM 32 位静态 ELF（板子上直接跑，不需要内核源码）
#   pl_download.ko   内核模块（vermagic + struct module 大小已对齐板子）
#
# 中间文件全部落在临时目录，不污染源码目录。
#
# ---------------------------------------------------------------------------
# 必须用 Zynq 的配置，不能用源码树当前的 .config
#
#   源码树 .config 现在是 sunxi 板子的配置（Allwinner 视频编解码那套），
#   直接编会有两个致命问题：
#     1. vermagic 变成 "6.18.39-current-sunxi ... thumb2 ..." → insmod 版本不匹配
#     2. **struct module 大小不同** →
#        "module: .gnu.linkonce.this_module section size must match
#         the kernel's built struct module size at run time"
#        这个错误只看 vermagic 是发现不了的，因为 vermagic 可以改对，
#        但 struct module 的字段受几十个 CONFIG 影响，必须整份配置一致。
#
#   Zynq 的真实配置备份在：$KDIR/../zynq-keep/config-zynq.txt
#   用它编出来的 .gnu.linkonce.this_module 大小 = 0x2c0 (704B)，
#   与板上能加载的 pl_load.ko 完全一致。
#
#   另外两个细节：
#     - olddefconfig 只更新 include/config/auto.conf，**不会**重新生成
#       include/config/kernel.release 和 include/generated/utsrelease.h，
#       必须删掉后跑 make prepare，否则 vermagic 还是旧值
#     - vermagic 结尾带一个空格（MODULE_ARCH_VERMAGIC 是 "p2v8 "），
#       校验用子串匹配，别用 grep -x
# ---------------------------------------------------------------------------

set -e

CROSS=${CROSS:-arm-linux-gnueabihf-}
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

EXPECT_VM="vermagic=6.18.39 SMP mod_unload ARMv7 p2v8"
EXPECT_MODSIZE="000002c0"     # 704 字节，与 pl_load.ko 一致

echo "=== 1) 编译用户态工具 pl_dl ==="
if ! command -v "${CROSS}gcc" >/dev/null 2>&1; then
    echo "错误: 找不到 ${CROSS}gcc，请确认 ARM 交叉工具链已安装" >&2
    exit 1
fi
"${CROSS}gcc" -O2 -Wall -static -o pl_dl pl_dl.c
echo "OK: $HERE/pl_dl"
ls -l pl_dl

echo
echo "=== 2) 编译内核模块 pl_download.ko ==="
if [ -z "$KDIR" ]; then
    echo "跳过: 未指定 KDIR"
    echo "  用法: sudo KDIR=/root/kernel-build/linux-6.18.39 ./build.sh"
    exit 0
fi

if [ ! -f "$KDIR/Makefile" ] || [ ! -f "$KDIR/Module.symvers" ]; then
    echo "错误: $KDIR 不是可用的内核源码树（需 Makefile + Module.symvers）" >&2
    exit 1
fi
if [ "$(id -u)" != "0" ]; then
    echo "错误: 改内核源码树需要 root，请用 sudo" >&2
    exit 1
fi

# 找 Zynq 配置
if [ -z "$ZCONFIG" ]; then
    for c in "$KDIR/../zynq-keep/config-zynq.txt" "$HERE/config-zynq.txt"; do
        if [ -f "$c" ]; then ZCONFIG="$c"; break; fi
    done
fi
if [ -z "$ZCONFIG" ] || [ ! -f "$ZCONFIG" ]; then
    echo "错误: 找不到 Zynq 配置（config-zynq.txt）" >&2
    echo "  用 ZCONFIG=/path/to/config-zynq.txt 指定" >&2
    echo "  或从板子取：zcat /proc/config.gz > config-zynq.txt" >&2
    exit 1
fi
echo "使用 Zynq 配置: $ZCONFIG"

CFG_BAK="$KDIR/.config.ko-build-backup"
echo "备份当前 .config -> $CFG_BAK"
cp "$KDIR/.config" "$CFG_BAK"

restore_cfg() {
    echo
    echo "恢复原 .config ..."
    cp "$CFG_BAK" "$KDIR/.config"
    make -C "$KDIR" ARCH=arm CROSS_COMPILE="$CROSS" olddefconfig >/dev/null 2>&1 || true
}
trap restore_cfg EXIT

echo "套用 Zynq 配置"
cp "$ZCONFIG" "$KDIR/.config"
make -C "$KDIR" ARCH=arm CROSS_COMPILE="$CROSS" olddefconfig >/dev/null 2>&1

echo "重新生成 kernel.release / utsrelease.h"
rm -f "$KDIR/include/config/kernel.release" "$KDIR/include/generated/utsrelease.h"
make -C "$KDIR" ARCH=arm CROSS_COMPILE="$CROSS" prepare >/dev/null 2>&1
echo -n "kernel.release = "; cat "$KDIR/include/config/kernel.release"

BUILD=$(mktemp -d /tmp/plko.XXXXXX)
echo "编译目录: $BUILD"
cp pl_download.c Makefile "$BUILD/"
make -C "$KDIR" M="$BUILD" ARCH=arm CROSS_COMPILE="$CROSS" modules 2>&1 | tail -10

echo
echo "=== 3) 校验 ==="
VM_OK=0; SZ_OK=0
strings "$BUILD/pl_download.ko" | grep -q "$EXPECT_VM" && VM_OK=1
MS=$(arm-linux-gnueabihf-objdump -h "$BUILD/pl_download.ko" 2>/dev/null \
     | awk '/this_module/ {print $3}')
[ "$MS" = "$EXPECT_MODSIZE" ] && SZ_OK=1

echo "vermagic    : $(strings "$BUILD/pl_download.ko" | grep '^vermagic=' | head -1)"
echo "             $([ $VM_OK -eq 1 ] && echo OK || echo MISMATCH)"
echo "this_module : 0x$MS (期望 0x$EXPECT_MODSIZE)"
echo "             $([ $SZ_OK -eq 1 ] && echo OK || echo MISMATCH)"

if [ $VM_OK -eq 1 ] && [ $SZ_OK -eq 1 ]; then
    cp "$BUILD/pl_download.ko" "$HERE/pl_download.ko"
    chmod 666 "$HERE/pl_download.ko"
    echo
    echo "OK: $HERE/pl_download.ko"
    ls -l "$HERE/pl_download.ko"
else
    echo
    echo "警告: 校验未全过，板子 insmod 可能失败" >&2
    cp "$BUILD/pl_download.ko" "$HERE/pl_download.ko.tmp"
    echo "产物留在 pl_download.ko.tmp 供检查" >&2
fi

rm -rf "$BUILD"
echo "中间文件已清理"
