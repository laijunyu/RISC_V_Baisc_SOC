// SPDX-License-Identifier: GPL-2.0
/*
 * pl_download.c - AXI UART Lite 程序下载驱动（EBAZ4205 / RISC-V SoC）
 *
 * 接口与 pl_load.ko 对称：
 *   pl_load  : echo xxx.bin > /sys/kernel/pl/load        （下 bitstream）
 *   pl_download: echo xxx.bin > /sys/kernel/pl_download/download （下 RISC-V 程序）
 *
 * 硬件通路：
 *   PS(M_AXI_GP0) -> AXI Protocol Converter -> AXI UART Lite(0x40600000)
 *     --TX--> SoC.uart_rx -> UART_BUS -> BOOT ROM -> HarvardSystemRAM
 *
 * 不需要设备树节点：AXI UART Lite 是纯 PL 硬件，PS 通过 M_AXI_GP0 访问，
 * 这里直接 ioremap，内核驱动模型完全不参与。
 *
 * 协议（BOOT ROM 反汇编确认）：
 *   'V'(0x56) + 块数(2字节,大端) + 'x'(0x78) + 数据(块数*16 字节)
 *   块 16 字节，上限 480 块 = 7680 字节，末尾不足 16 字节补 0。
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/fs.h>
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>
#include <linux/io.h>
#include <linux/uaccess.h>
#include <linux/slab.h>
#include <linux/delay.h>
#include <linux/mutex.h>
#include <linux/firmware.h>
#include <linux/string.h>
#include <linux/sched.h>

#define DRV_NAME    "pl_download"
#define DRV_VERSION "1.0"

/* ---- 硬件参数 ---- */
#define ULITE_PHYS_BASE  0x40600000UL   /* Vivado Address Editor 分配 */
#define ULITE_PHYS_SIZE  0x1000UL

/* AXI UART Lite 寄存器偏移 */
#define ULITE_RX_FIFO    0x00
#define ULITE_TX_FIFO    0x04
#define ULITE_STAT       0x08
#define ULITE_CTRL       0x0C

/* STAT 位 */
#define ULITE_STAT_RX_VALID  BIT(0)
#define ULITE_STAT_RX_FULL   BIT(1)
#define ULITE_STAT_TX_EMPTY  BIT(2)
#define ULITE_STAT_TX_FULL   BIT(3)

/* CTRL 位 */
#define ULITE_CTRL_RST_TX    BIT(0)
#define ULITE_CTRL_RST_RX    BIT(1)

/* ---- BOOT ROM 下载协议 ---- */
#define DL_BLOCK_SIZE   16
#define DL_MAX_BLOCKS   480
#define DL_MAX_BYTES    (DL_BLOCK_SIZE * DL_MAX_BLOCKS)   /* 7680 */
#define DL_MAGIC_HEAD   0x56    /* 'V' 帧头 */
#define DL_MAGIC_DATA   0x78    /* 'x' 数据开始 */
#define DL_MAGIC_DONE   0x57    /* 'W' 完成确认（BOOT ROM 收完数据后必须收到这个） */

struct pl_dl {
    void __iomem *base;
    struct cdev cdev;
    dev_t devno;
    struct class *cls;
    struct device *dev;

    struct mutex lock;
    u8 *buf;        /* 字符设备累积缓冲 */
    size_t len;
};

static struct pl_dl *g_pl;
static struct kobject *pl_kobj;

/*
 * 是否在 init 时访问硬件（读 STAT / 复位 FIFO）。
 *
 * 默认 0，因为 Zynq 的 PS 访问一个未响应的 AXI 从设备时不是返回错误，
 * 而是让 CPU 永久挂在总线上（连中断都进不去，软件看门狗救不了）。
 * bitstream 没加载 / 地址没映射时，insmod 里任何一次 readl/writel 都会卡死系统。
 *
 * 确认硬件就绪后，用 insmod pl_download.ko probe_hw=1 打开。
 */
static bool probe_hw;
module_param(probe_hw, bool, 0644);
MODULE_PARM_DESC(probe_hw, "在 init 时访问硬件（默认 0，避免 AXI 未响应时挂死）");

/* ---------------- AXI UART Lite 底层 ---------------- */

static inline void ulite_putc(struct pl_dl *p, u8 c)
{
    int timeout = 200000;

    while ((readl(p->base + ULITE_STAT) & ULITE_STAT_TX_FULL) && --timeout)
        udelay(1);
    if (unlikely(timeout <= 0))
        pr_warn(DRV_NAME ": TX FIFO 持续满，丢弃 0x%02x\n", c);

    writel(c, p->base + ULITE_TX_FIFO);
}

/*
 * 读 RX FIFO 并打印到 dmesg。
 *
 * 为什么需要：SoC 侧 RX FIFO 只有 16 字节，而 BOOT ROM 会打印
 * "Len=" / "💾:0x78" / "✅:0x57" 等调试信息，随后又回到 0x80 打印 "🔓:0x56"，
 * 等下载完再读就只剩 🔓 了。所以在发送的间隙立刻抓一次。
 */
static void ulite_dump_rx(struct pl_dl *p, int n, const char *tag)
{
    u32 stat = readl(p->base + ULITE_STAT);
    char buf[64];
    char hex[160];
    int i, len = 0, hlen = 0;

    /*
     * ⚠️⚠️ 致命陷阱：AXI UART Lite 在 RX FIFO 为空时读 0x00 偏移，
     * AXI 会返回 SLVERR。ARM 上这表现为 "external abort on non-linefetch"，
     * 在**内核态**就是直接 panic 或者 CPU 永久挂在总线上（D 状态，只能断电）。
     * （实测：FIFO 有数据时读正常，FIFO 空时必报 SLVERR，100% 复现）
     *
     * 所以每次读 RX FIFO 之前都必须先查 STAT 的 bit0 = RX_FIFO_VALID_DATA。
     * 绝对不能盲读 n 次。
     */
    for (i = 0; i < n && i < 32; i++) {
        u32 v;

        if (!(readl(p->base + ULITE_STAT) & ULITE_STAT_RX_VALID))
            break;

        v = readl(p->base + ULITE_RX_FIFO);
        buf[len++] = ((v & 0xFF) >= 0x20 && (v & 0xFF) < 0x7F) ? (char)(v & 0xFF) : '.';
        hlen += snprintf(hex + hlen, sizeof(hex) - hlen, "%02x ", v & 0xFF);
    }
    buf[len] = '\0';
    if (hlen == 0)
        snprintf(hex, sizeof(hex), "(empty)");

    pr_info(DRV_NAME ": [%s] STAT=0x%08x n=%d RX=\"%s\" HEX=[%s]\n",
            tag, stat, len, buf, hex);
}

/*
 * 在 timeout_ms 内持续排空 RX，寻找 expect 子串。
 *
 * 为什么不能用固定延时：BOOT ROM 在等 'V' 的时候是
 *   「打印 🔓:0x56 → 查状态 → 没数据 → 再打印」
 * 的死循环（Rom_Pkg.sv 的 0x80~0x9c），每 4.7ms 吐 9 个字节，
 * 而 uartlite 的 RX FIFO 只有 16 字节，不排空就溢出成乱码。
 *
 * 返回 0 = 匹配成功，-ETIMEDOUT = 超时（说明 SoC 根本不在预期状态）。
 */
static int ulite_expect(struct pl_dl *p, const char *expect, int timeout_ms)
{
    size_t want = strlen(expect);
    size_t matched = 0;
    int waited = 0;
    char log[64];
    int llen = 0;

    while (waited < timeout_ms) {
        u32 stat = readl(p->base + ULITE_STAT);

        if (stat & ULITE_STAT_RX_VALID) {
            u32 v = readl(p->base + ULITE_RX_FIFO);
            u8 c = (u8)(v & 0xFF);

            if (llen < (int)sizeof(log) - 1)
                log[llen++] = (c >= 0x20 && c < 0x7F) ? (char)c : '.';

            if (c == (u8)expect[matched]) {
                if (++matched == want) {
                    log[llen] = '\0';
                    pr_info(DRV_NAME ": 匹配 \"%s\" (RX=\"%s\")\n", expect, log);
                    return 0;
                }
            } else {
                matched = (c == (u8)expect[0]) ? 1 : 0;
            }
        } else {
            msleep(1);
            waited++;
        }
    }

    log[llen] = '\0';
    pr_err(DRV_NAME ": 超时 %dms 未匹配 \"%s\" (RX=\"%s\")\n",
           timeout_ms, expect, log);
    return -ETIMEDOUT;
}

/*
 * 按 BOOT ROM 协议发送：'V' + 块数(大端) + 'x' + 数据(补零到 16 字节) + 'W'
 *
 * ⚠️ 关键：SoC 侧 UART_BUS 只有 4 字节接收 FIFO，而 BOOT ROM 在收到 'V' 后
 * 会先打印 "Len="、收到 'x' 后先打印 "💾:0x78"（每次约 5ms），期间 UART 还在
 * 连续来数据，4 字节 FIFO 立刻溢出，关键字节被冲掉，导致 BOOT ROM 一直卡在
 * 0x80 反复打印 "🔓:0x56"、永远认不出 'V'。
 * 所以在 'V' 和 'x' 之后各留 20ms 让 BOOT ROM 把字符串打印完，
 * 并顺便把它的响应抓进 dmesg 方便确认进度。
 */
static int ulite_download(struct pl_dl *p, const u8 *data, size_t len)
{
    u16 blocks = (u16)DIV_ROUND_UP(len, DL_BLOCK_SIZE);
    size_t total = (size_t)blocks * DL_BLOCK_SIZE;
    size_t i;

    /* ---- 1. 握手：'V' → 等 "Len=" ---- */
    ulite_putc(p, DL_MAGIC_HEAD);
    if (ulite_expect(p, "Len=", 500))
        return -ETIMEDOUT;

    /* ---- 2. 块数 + 'x' → 等 "💾:0x78" ---- */
    ulite_putc(p, (u8)(blocks >> 8));
    ulite_putc(p, (u8)(blocks & 0xFF));
    ulite_putc(p, DL_MAGIC_DATA);
    if (ulite_expect(p, "0x78", 500))
        return -ETIMEDOUT;

    /*
     * ⚠️ 关键：ROM 打印完 "💾:0x78" 之后、开始收数据之前有一段空转延时
     * （Rom_Pkg.sv 的 0x0d8~0x0e0，0x36F000 = 3,600,384 次 ≈ 1.2s @12MHz）。
     * 这段时间 SoC 完全不读 UART，而它的接收 FIFO 只有 4 字节。
     * 立刻猛发数据 → 当场溢出、字节全丢 → SoC 永远等不到最后一个字节，
     * 也就不会打印 "✅:0x57"。
     *
     * 之前这里只 msleep(20)，是 2026-11-15 移植时漏掉的，导致下载"成功"
     * 但 RAM 里全是垃圾。
     */
    msleep(1500);

    /* ---- 3. 数据 + 'W' → 等 "✅:0x57" ---- */
    for (i = 0; i < total; i++) {
        ulite_putc(p, (i < len) ? data[i] : 0x00);
        if ((i & 0xFF) == 0)
            cond_resched();
    }

    ulite_putc(p, DL_MAGIC_DONE);
    if (ulite_expect(p, "0x57", 1000))
        return -ETIMEDOUT;

    return 0;
}

/* ---------------- sysfs: /sys/kernel/pl_download/ ---------------- */

static ssize_t download_store(struct kobject *kobj, struct kobj_attribute *attr,
                              const char *buf, size_t count)
{
    struct pl_dl *p = g_pl;
    const struct firmware *fw;
    char name[256];
    size_t n = count;
    int ret;

    if (n && buf[n - 1] == '\n')
        n--;
    if (n == 0 || n >= sizeof(name))
        return -EINVAL;

    memcpy(name, buf, n);
    name[n] = '\0';

    ret = request_firmware(&fw, name, NULL);
    if (ret) {
        pr_err(DRV_NAME ": 加载固件 '%s' 失败 (%d)\n", name, ret);
        return ret;
    }

    if (fw->size == 0 || fw->size > DL_MAX_BYTES) {
        pr_err(DRV_NAME ": %s 大小 %zu 不合法（上限 %d）\n",
               name, fw->size, DL_MAX_BYTES);
        release_firmware(fw);
        return -EFBIG;
    }

    mutex_lock(&p->lock);
    ret = ulite_download(p, fw->data, fw->size);
    mutex_unlock(&p->lock);

    release_firmware(fw);

    if (ret) {
        pr_err(DRV_NAME ": '%s' 下载失败 (%d) —— SoC 没按预期回执。\n"
               "  检查：① K1 是否按住 + 按过 U20 复位（加载 bitstream 会清空 BRAM，\n"
               "         SoC 会掉进 ROM 闪灯循环，不是下载模式）\n"
               "        ② bitstream 是否是 top_wrapper_gpio.bin\n",
               name, ret);
        return ret;
    }

    pr_info(DRV_NAME ": '%s' 下载成功，已收到 ✅:0x57\n", name);
    return count;
}

static ssize_t status_show(struct kobject *kobj, struct kobj_attribute *attr,
                           char *buf)
{
    /*
     * 这里**故意不读 STAT 寄存器**。
     * readl 会真的发起 AXI 读事务，若 PL 里没有这个从设备，整个系统当场挂死。
     * 想看 STAT 请显式写 probe=1（用户自愿承担风险）。
     */
    return sysfs_emit(buf,
        "base      : 0x%08lx (size 0x%lx)\n"
        "baud      : 19200\n"
        "max_bytes : %d (%d blocks x %d bytes)\n"
        "hw_state  : 未探测（读 STAT 会访问 AXI，设备未就绪时会挂死系统）\n"
        "            确认 bitstream 已加载后：echo 1 > probe\n",
        (unsigned long)ULITE_PHYS_BASE, (unsigned long)ULITE_PHYS_SIZE,
        DL_MAX_BYTES, DL_MAX_BLOCKS, DL_BLOCK_SIZE);
}

/*
 * echo 1 > probe —— 主动读一次 STAT。
 * 只有确认 bitstream 里真的有 AXI UART Lite 时才用，否则系统会挂。
 */
static ssize_t probe_store(struct kobject *kobj, struct kobj_attribute *attr,
                           const char *buf, size_t count)
{
    unsigned long v;
    u32 stat;

    if (kstrtoul(buf, 0, &v) || v != 1)
        return -EINVAL;

    stat = readl(g_pl->base + ULITE_STAT);
    pr_info(DRV_NAME ": STAT=0x%08x  rx_valid=%d rx_full=%d tx_empty=%d tx_full=%d\n",
            stat,
            !!(stat & ULITE_STAT_RX_VALID), !!(stat & ULITE_STAT_RX_FULL),
            !!(stat & ULITE_STAT_TX_EMPTY), !!(stat & ULITE_STAT_TX_FULL));

    /* 顺手把 RX FIFO 里已有的字节抓出来（带 STAT 保护，不会空读） */
    ulite_dump_rx(g_pl, 24, "probe");

    return count;
}

static struct kobj_attribute download_attr =
    __ATTR(download, 0200, NULL, download_store);
static struct kobj_attribute status_attr =
    __ATTR(status, 0444, status_show, NULL);
static struct kobj_attribute probe_attr =
    __ATTR(probe, 0200, NULL, probe_store);

/* ---------------- 字符设备 /dev/pl_download ---------------- */

static int pl_open(struct inode *inode, struct file *filp)
{
    filp->private_data = g_pl;
    return 0;
}

/* write 只累积，close 时才发送 → cat blink.bin > /dev/pl_download 自动下载 */
static ssize_t pl_write(struct file *filp, const char __user *ubuf,
                        size_t count, loff_t *ppos)
{
    struct pl_dl *p = filp->private_data;
    size_t space;
    int ret = 0;

    if (mutex_lock_interruptible(&p->lock))
        return -ERESTARTSYS;

    space = DL_MAX_BYTES - p->len;
    if (count > space) {
        pr_err(DRV_NAME ": 超出上限（本次 %zu, 剩余 %zu, 上限 %d）\n",
               count, space, DL_MAX_BYTES);
        ret = -EFBIG;
        goto out;
    }

    if (copy_from_user(p->buf + p->len, ubuf, count)) {
        ret = -EFAULT;
        goto out;
    }

    p->len += count;
    *ppos += count;
    ret = count;

out:
    mutex_unlock(&p->lock);
    return ret;
}

static int pl_release(struct inode *inode, struct file *filp)
{
    struct pl_dl *p = filp->private_data;

    mutex_lock(&p->lock);
    if (p->len > 0) {
        ulite_download(p, p->buf, p->len);
        p->len = 0;
    }
    mutex_unlock(&p->lock);
    return 0;
}

static const struct file_operations pl_fops = {
    .owner   = THIS_MODULE,
    .open    = pl_open,
    .write   = pl_write,
    .release = pl_release,
};

/* ---------------- 加载 / 卸载 ---------------- */

static int __init pl_init(void)
{
    struct pl_dl *p;
    int ret;

    p = kzalloc(sizeof(*p), GFP_KERNEL);
    if (!p)
        return -ENOMEM;

    mutex_init(&p->lock);

    p->buf = kmalloc(DL_MAX_BYTES, GFP_KERNEL);
    if (!p->buf) {
        ret = -ENOMEM;
        goto err_free;
    }

    p->base = ioremap(ULITE_PHYS_BASE, ULITE_PHYS_SIZE);
    if (!p->base) {
        ret = -ENOMEM;
        goto err_buf;
    }

    /*
     * ioremap 只建页表映射，不发起 AXI 事务，是安全的。
     * 但 readl/writel 会真的访问总线 —— 设备不在就挂死，所以默认不碰。
     */
    if (probe_hw) {
        pr_info(DRV_NAME ": probe_hw=1，访问硬件做 FIFO 复位\n");
        writel(ULITE_CTRL_RST_TX | ULITE_CTRL_RST_RX, p->base + ULITE_CTRL);
        udelay(10);
        pr_info(DRV_NAME ": STAT=0x%08x\n", readl(p->base + ULITE_STAT));
    }

    ret = alloc_chrdev_region(&p->devno, 0, 1, DRV_NAME);
    if (ret)
        goto err_iomap;

    cdev_init(&p->cdev, &pl_fops);
    p->cdev.owner = THIS_MODULE;
    ret = cdev_add(&p->cdev, p->devno, 1);
    if (ret)
        goto err_chrdev;

    p->cls = class_create(DRV_NAME);      /* 6.4+ 只接受 name */
    if (IS_ERR(p->cls)) {
        ret = PTR_ERR(p->cls);
        goto err_cdev;
    }

    p->dev = device_create(p->cls, NULL, p->devno, NULL, DRV_NAME);
    if (IS_ERR(p->dev)) {
        ret = PTR_ERR(p->dev);
        goto err_class;
    }

    /* /sys/kernel/pl_download/{download,status} */
    pl_kobj = kobject_create_and_add(DRV_NAME, kernel_kobj);
    if (!pl_kobj) {
        ret = -ENOMEM;
        goto err_dev;
    }
    if (sysfs_create_file(pl_kobj, &download_attr.attr)) {
        ret = -EIO;
        goto err_kobj;
    }
    if (sysfs_create_file(pl_kobj, &status_attr.attr)) {
        ret = -EIO;
        goto err_kobj2;
    }
    if (sysfs_create_file(pl_kobj, &probe_attr.attr)) {
        ret = -EIO;
        goto err_kobj3;
    }

    g_pl = p;

    pr_info(DRV_NAME ": v%s ready, AXI UART Lite @0x%08lx, "
            "echo <file.bin> > /sys/kernel/" DRV_NAME "/download\n",
            DRV_VERSION, (unsigned long)ULITE_PHYS_BASE);
    return 0;

err_kobj3:
    sysfs_remove_file(pl_kobj, &status_attr.attr);
err_kobj2:
    sysfs_remove_file(pl_kobj, &download_attr.attr);
err_kobj:
    kobject_put(pl_kobj);
err_dev:
    device_destroy(p->cls, p->devno);
err_class:
    class_destroy(p->cls);
err_cdev:
    cdev_del(&p->cdev);
err_chrdev:
    unregister_chrdev_region(p->devno, 1);
err_iomap:
    iounmap(p->base);
err_buf:
    kfree(p->buf);
err_free:
    kfree(p);
    return ret;
}

static void __exit pl_exit(void)
{
    struct pl_dl *p = g_pl;

    if (!p)
        return;

    if (pl_kobj) {
        sysfs_remove_file(pl_kobj, &probe_attr.attr);
        sysfs_remove_file(pl_kobj, &status_attr.attr);
        sysfs_remove_file(pl_kobj, &download_attr.attr);
        kobject_put(pl_kobj);
        pl_kobj = NULL;
    }
    device_destroy(p->cls, p->devno);
    class_destroy(p->cls);
    cdev_del(&p->cdev);
    unregister_chrdev_region(p->devno, 1);
    iounmap(p->base);
    kfree(p->buf);
    kfree(p);
    g_pl = NULL;

    pr_info(DRV_NAME ": unloaded\n");
}

module_init(pl_init);
module_exit(pl_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("EBAZ4205");
MODULE_DESCRIPTION("AXI UART Lite program downloader for RISC-V SoC");
MODULE_VERSION(DRV_VERSION);
