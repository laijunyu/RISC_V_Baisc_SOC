/*
 * pl_dl.c - AXI UART Lite 程序下载工具（用户态版）
 *
 * 和 pl_download.ko 功能相同，但**不需要内核源码树**，
 * 只要 ARM 交叉工具链就能编，适合先验证硬件通路。
 *
 * 原理：mmap /dev/mem 映射 AXI UART Lite 寄存器，直接轮询 TX FIFO 发数据。
 *
 * 编译：
 *   arm-linux-gnueabihf-gcc -O2 -static -o pl_dl pl_dl.c
 *
 * 用法（板子 Linux 上，root）：
 *   ./pl_dl -c            # 只检查：读一次 STAT，确认设备在（这一步有挂死风险）
 *   ./pl_dl blink.bin     # 下载程序
 *
 * ⚠️ Zynq 的坑：PS 访问一个未响应的 AXI 从设备时不会返回错误，
 *    而是让 CPU 永久挂在总线上（中断都进不去）。
 *    所以 **必须先确认 bitstream 里真的有 AXI UART Lite @0x40600000**，
 *    否则 `-c` 和下载都会把系统挂死。
 *
 * 前置条件：
 *   1. 新 bitstream 已加载（含 AXI UART Lite @0x40600000）
 *   2. K1 按住（低电平 = SoC 进下载模式）
 *   3. 下载完成后先松 K1，再复位 SoC
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/stat.h>

#define ULITE_PHYS_BASE  0x40600000UL
#define ULITE_PHYS_SIZE  0x1000UL

#define ULITE_RX_FIFO    0x00
#define ULITE_TX_FIFO    0x04
#define ULITE_STAT       0x08
#define ULITE_CTRL       0x0C

#define STAT_RX_VALID    (1u << 0)
#define STAT_RX_FULL     (1u << 1)
#define STAT_TX_EMPTY    (1u << 2)
#define STAT_TX_FULL     (1u << 3)

#define CTRL_RST_TX      (1u << 0)
#define CTRL_RST_RX      (1u << 1)

#define DL_BLOCK_SIZE    16
#define DL_MAX_BLOCKS    480
#define DL_MAX_BYTES     (DL_BLOCK_SIZE * DL_MAX_BLOCKS)

static volatile uint32_t *regs;

/* 映射 /dev/mem 里的 UART Lite 寄存器区。只建映射，不访问总线，安全。 */
static int map_regs(void)
{
    int fd;
    void *map;

    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "打开 /dev/mem 失败: %s（需要 root）\n", strerror(errno));
        return -1;
    }

    map = mmap(NULL, ULITE_PHYS_SIZE, PROT_READ | PROT_WRITE,
               MAP_SHARED, fd, (off_t)ULITE_PHYS_BASE);
    if (map == MAP_FAILED) {
        fprintf(stderr, "mmap 0x%08lx 失败: %s\n",
                (unsigned long)ULITE_PHYS_BASE, strerror(errno));
        close(fd);
        return -1;
    }

    regs = (volatile uint32_t *)map;
    close(fd);   /* 映射已建立，fd 可以关掉 */
    return 0;
}

static void unmap_regs(void)
{
    if (regs)
        munmap((void *)regs, ULITE_PHYS_SIZE);
}

static inline void ulite_putc(uint8_t c)
{
    int timeout = 200000;

    while ((regs[ULITE_STAT / 4] & STAT_TX_FULL) && --timeout)
        ;
    if (timeout <= 0) {
        fprintf(stderr, "警告: TX FIFO 一直满, 丢弃字节 0x%02x\n", c);
        return;
    }
    regs[ULITE_TX_FIFO / 4] = c;
}

/*
 * 安全地读一个 RX 字节。
 *
 * ⚠️⚠️ 致命陷阱：AXI UART Lite 在 RX FIFO 为空时读 0x00 偏移会返回 SLVERR，
 * ARM 上是 "external abort on non-linefetch" → 用户态是 Bus error，
 * 内核态直接 panic / 挂死（只能断电）。
 * 实测：FIFO 有数据时读正常，FIFO 空时必报错，100% 复现。
 * 所以每次读之前必须查 STAT bit0。
 */
static int ulite_getc(uint8_t *out)
{
    if (!(regs[ULITE_STAT / 4] & STAT_RX_VALID))
        return 0;
    *out = (uint8_t)(regs[ULITE_RX_FIFO / 4] & 0xFF);
    return 1;
}

/* 抓 RX 里已有的数据并打印（只在 STAT 说有数据时才读） */
static void ulite_dump_rx(const char *tag, int max)
{
    char buf[80];
    int len = 0, i;
    uint8_t c;

    for (i = 0; i < max && i < 70; i++) {
        if (!ulite_getc(&c))
            break;
        buf[len++] = (c >= 0x20 && c < 0x7F) ? (char)c : '.';
    }
    buf[len] = '\0';
    printf("  [%-8s] RX(%2d) = \"%s\"\n", tag, len, buf);
}

/*
 * 在 timeout_ms 内持续排空 RX，寻找 expect 子串。
 *
 * 为什么不能靠固定延时：BOOT ROM 在等 'V' 的时候是
 *   「打印 🔓:0x56 → 查状态 → 没数据 → 再打印」
 * 的死循环（见 Rom_Pkg.sv 的 0x80~0x9c），每 4.7ms 吐 9 个字节，
 * 而 uartlite 的 RX FIFO 只有 16 字节，不排空就溢出成乱码。
 * 所以必须一边排空一边匹配，不能 sleep 完再读。
 *
 * 返回 0 = 匹配成功，-1 = 超时。
 */
static int ulite_expect(const char *expect, int timeout_ms)
{
    size_t want = strlen(expect);
    size_t matched = 0;
    int waited = 0;
    char log[128];
    int llen = 0;

    while (waited < timeout_ms) {
        uint8_t c;

        if (ulite_getc(&c)) {
            if (llen < (int)sizeof(log) - 1)
                log[llen++] = (c >= 0x20 && c < 0x7F) ? (char)c : '.';

            if (c == (uint8_t)expect[matched]) {
                if (++matched == want) {
                    log[llen] = '\0';
                    printf("  RX=\"%s\"  ==> 匹配 \"%s\"\n", log, expect);
                    return 0;
                }
            } else {
                matched = (c == (uint8_t)expect[0]) ? 1 : 0;
            }
        } else {
            usleep(1000);
            waited++;
        }
    }

    log[llen] = '\0';
    printf("  RX=\"%s\"  ==> 超时(%dms) 未匹配 \"%s\"\n", log, timeout_ms, expect);
    return -1;
}

/*
 * 协议：'V' + 块数(大端) + 'x' + 数据 + 'W'
 *
 * 每一步都等 BOOT ROM 打印出对应的回执再继续，不用固定延时瞎猜：
 *   'V'          -> "Len="      (PRELOAD_STR 第 2 段)
 *   块数 + 'x'   -> "💾:0x78"   (第 3 段)
 *   数据 + 'W'   -> "✅:0x57"   (第 4 段)
 */
static int ulite_download(const uint8_t *data, size_t len)
{
    unsigned blocks = (len + DL_BLOCK_SIZE - 1) / DL_BLOCK_SIZE;
    size_t total = (size_t)blocks * DL_BLOCK_SIZE;
    size_t i;

    printf("  发送 'V' ...\n");
    ulite_putc(0x56);
    if (ulite_expect("Len=", 500) != 0)
        return -1;

    printf("  发送块数 %u + 'x' ...\n", blocks);
    ulite_putc((blocks >> 8) & 0xFF);
    ulite_putc(blocks & 0xFF);
    ulite_putc(0x78);                       /* 'x' */
    if (ulite_expect("0x78", 500) != 0)
        return -1;

    /*
     * ⚠️ 关键：ROM 在打印完 "💾:0x78" 之后、开始收数据之前，
     * 有一段空转延时（Rom_Pkg.sv 的 0x0d8~0x0e0）：
     *     lui  x5, 0x36f        ; x5 = 0x36F000 = 3,600,384
     *     addi x5, x5, -1
     *     bne  x5, x0, -4
     * 约 360 万次循环 ≈ 1.2s @12MHz。
     *
     * 这段时间 SoC 完全不读 UART，而它的接收 FIFO 只有 4 字节。
     * 如果立刻猛发数据，FIFO 当场溢出、字节全丢，SoC 永远等不到
     * 最后一个字节，也就不会打印 "✅:0x57"。
     * 所以必须等它空转完再发。
     */
    printf("  等 SoC 空转 1.2s ...\n");
    usleep(1500000);

    printf("  发送 %zu 字节数据 ...\n", total);
    for (i = 0; i < total; i++)
        ulite_putc(i < len ? data[i] : 0x00);

    printf("  发送 'W' ...\n");
    ulite_putc(0x57);
    if (ulite_expect("0x57", 1000) != 0)
        return -1;

    return 0;
}

static uint8_t *read_file(const char *path, size_t *out_len)
{
    FILE *f = fopen(path, "rb");
    uint8_t *buf;
    long sz;

    if (!f) {
        fprintf(stderr, "打不开 %s: %s\n", path, strerror(errno));
        return NULL;
    }
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    sz = ftell(f);
    if (sz < 0) { fclose(f); return NULL; }
    rewind(f);

    buf = malloc((size_t)sz);
    if (!buf) {
        fprintf(stderr, "内存不足\n");
        fclose(f);
        return NULL;
    }
    if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
        fprintf(stderr, "读 %s 失败\n", path);
        free(buf);
        fclose(f);
        return NULL;
    }
    fclose(f);
    *out_len = (size_t)sz;
    return buf;
}

static void usage(const char *prog)
{
    fprintf(stderr,
        "用法:\n"
        "  %s -c             只检查设备（读一次 STAT，有挂死风险）\n"
        "  %s <程序.bin>     下载程序\n"
        "例:\n"
        "  %s -c\n"
        "  %s blink.bin\n", prog, prog, prog, prog);
}

int main(int argc, char **argv)
{
    uint8_t *data;
    size_t len;
    unsigned blocks;

    if (argc != 2) {
        usage(argv[0]);
        return 1;
    }

    if (map_regs() != 0)
        return 1;

    /* ---- 只检查模式 ---- */
    if (strcmp(argv[1], "-c") == 0 || strcmp(argv[1], "--check") == 0) {
        uint32_t stat;

        printf("AXI UART Lite @0x%08lx\n", (unsigned long)ULITE_PHYS_BASE);
        printf("正在读 STAT 寄存器（设备不存在会挂死系统）...\n");
        fflush(stdout);

        stat = regs[ULITE_STAT / 4];

        printf("STAT = 0x%08x\n", stat);
        printf("  rx_valid=%d  rx_full=%d  tx_empty=%d  tx_full=%d\n",
               !!(stat & STAT_RX_VALID), !!(stat & STAT_RX_FULL),
               !!(stat & STAT_TX_EMPTY), !!(stat & STAT_TX_FULL));
        ulite_dump_rx("pending", 24);
        printf("设备响应正常。\n");
        unmap_regs();
        return 0;
    }

    /* ---- 下载模式 ---- */
    data = read_file(argv[1], &len);
    if (!data) {
        unmap_regs();
        return 1;
    }

    if (len == 0 || len > DL_MAX_BYTES) {
        fprintf(stderr, "文件大小 %zu 不合法（上限 %d 字节 = %d 块）\n",
                len, DL_MAX_BYTES, DL_MAX_BLOCKS);
        free(data);
        unmap_regs();
        return 1;
    }
    blocks = (len + DL_BLOCK_SIZE - 1) / DL_BLOCK_SIZE;

    printf("AXI UART Lite @0x%08lx\n", (unsigned long)ULITE_PHYS_BASE);
    printf("复位 FIFO 并下载 %s: %zu 字节 -> %u 块 (每块 %d 字节)\n",
           argv[1], len, blocks, DL_BLOCK_SIZE);
    fflush(stdout);

    regs[ULITE_CTRL / 4] = CTRL_RST_TX | CTRL_RST_RX;
    usleep(1000);

    if (ulite_download(data, len) != 0) {
        printf("\n*** 下载失败：SoC 没按预期回执 ***\n");
        unmap_regs();
        free(data);
        return 2;
    }

    /* 等 TX FIFO 排空 */
    {
        int timeout = 500000;
        while (!(regs[ULITE_STAT / 4] & STAT_TX_EMPTY) && --timeout)
            usleep(10);
    }

    printf("\n*** 下载成功：SoC 回了 ✅:0x57 ***\n");
    printf("下一步: 复位 SoC（U20）让它从 RAM 跑刚下载的程序。\n");
    printf("       注意 BOOT ROM 会检查 RAM[0] bit0，非 0 才进 RAM 模式。\n");

    unmap_regs();
    free(data);
    return 0;
}
