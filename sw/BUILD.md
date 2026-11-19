# RISC-V 程序编译与接口手册

面向本工程 `RISC_v_Bisac_User` 里的 RV32I 软核（XT RISC-V Soc）。
所有内容均从 RTL 源码和本机实测得出，不是推测。

---

# 第一部分：编译

## 1. 工具链

**不用另装**，Vitis 自带，就在 Vivado 安装目录里。

```bash
export PATH=/d/vivado/2026.1/gnu/riscv/nt/bin:$PATH
```

| 项 | 值 |
|---|---|
| 编译器 | `riscv64-unknown-elf-gcc`（实际报 `riscv32-xilinx-elf-gcc`） |
| 版本 | GCC 13.4.0 |
| 多库配置 | 含 `rv32i/ilp32`，正好匹配本核 |
| libc | newlib（`libc.a` / `libm.a` / `libgcc.a`） |
| 位置 | `/d/vivado/2026.1/gnu/riscv/nt/bin/` |

工具链**不在 PATH 里**，每次开新终端都要先 export。
Windows PATH 和 WSL 里都**没有** riscv 工具链，只有 Vivado 这一份。

## 2. 两个必须写死的参数

```bash
-march=rv32i -mabi=ilp32
```

**不能省。** 不写默认 rv64，生成的指令核认不了。

本核是纯 **RV32I**（**没有 M 扩展 = 没有硬件乘除法**）：

- 乘/除/取模要用 `-lgcc` 的软件实现，**链接时不要漏 `-lgcc`**
- 不要用 `-march=rv32im`，会生成 `mul` 指令，核不支持
- 不要用 `rv32ic`（压缩指令），核不支持

## 3. 编译步骤（汇编版）

```bash
cd RISC_v_Bisac_User/sw
export PATH=/d/vivado/2026.1/gnu/riscv/nt/bin:$PATH

# ① 汇编 → 目标文件
riscv64-unknown-elf-as -march=rv32i -mabi=ilp32 -o blink.o blink.S

# ② 链接 → ELF（必须带链接脚本）
riscv64-unknown-elf-ld -T link.ld -o blink.elf blink.o

# ③ 提取纯二进制（下载用这个）
riscv64-unknown-elf-objcopy -O binary blink.elf blink.bin

# ④ 检查大小（上限 7680 字节）
ls -l blink.bin
```

| 步骤 | 产物 | 用途 |
|---|---|---|
| ① | `blink.o` | 中间文件，可删 |
| ② | `blink.elf` | 带符号，用来 `objdump -d` 反汇编调试 |
| ③ | `blink.bin` | **下载到板子的是这个** |

这套命令重编 `blink.S` 得到的 `blink.bin` 与原文件 **MD5 完全一致**
（`f3feb4bbd4d4fea4313f4d5126efa98e`，112 字节）。

## 4. 编译步骤（C 版，必须配 crt0.S）

```bash
cd RISC_v_Bisac_User/sw
export PATH=/d/vivado/2026.1/gnu/riscv/nt/bin:$PATH

# ① 编译 + 链接一步到位（crt0.S 必须放在源文件列表最前）
riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -O2 \
    -nostdlib -nostartfiles -ffreestanding \
    -T link.ld -o app.elf crt0.S app.c -lgcc

# ② 提取二进制
riscv64-unknown-elf-objcopy -O binary app.elf app.bin

# ③ 检查大小
ls -l app.bin

# ④（可选）反汇编确认 sp 已初始化
riscv64-unknown-elf-objdump -d app.elf | head -20
```

预期反汇编开头：

```
00000000 <_start>:
   0: lui   sp,0x2              ← sp = 0x2000
   4: lui   gp,0x2
   8: addi  gp,gp,-2048         ← gp = 0x1800
   c: jal   ra,xxx <main>
  10: j     10
```

实测一个带递归函数调用的 C 程序：**1,296 字节**，空间很宽裕。

### 每个编译选项的作用

| 选项 | 作用 | 去掉会怎样 |
|---|---|---|
| `-march=rv32i -mabi=ilp32` | 指定指令集和 ABI | 默认 rv64，核认不了 |
| `-O2` | 优化 | 体积大好几倍 |
| `-nostdlib` | 不链 newlib 的启动代码和默认库 | printf 会把体积撑到 78KB |
| `-nostartfiles` | 不链 newlib 的 `crt0.o` | 和 `crt0.S` 里的 `_start` 重复定义 |
| `-ffreestanding` | 告诉编译器没有宿主环境 | 可能生成对 libc 的隐含调用 |
| `-T link.ld` | 用我们的链接脚本 | 起始地址不对，跑飞 |
| `-lgcc` | 软件乘除法 | `undefined reference to '__mulsi3'` |

### 为什么不能用 newlib 的 printf

| 写法 | 体积 | 能下载吗 |
|---|---|---|
| 带 `printf`（newlib） | **78,904 字节** | ❌ 超上限 10 倍 |
| `-nostdlib -ffreestanding` | 1,296 字节 | ✅ |

下载上限是 **480 块 × 16 = 7,680 字节**（对应原 Lattice UFM 的 7680 字节），
RAM 本身只有 8 KB。所以 **printf / malloc / 文件 IO 全部用不了**。
需要输出就自己往 UART 寄存器写字节，见第二部分。

## 5. 启动文件 crt0.S

内核的寄存器堆**复位时不做初始化**（`RISC_V/Core/CoreReg.sv`）：

```systemverilog
if (!rst && (stall_n || debug.halted) && wen && waddr != 0) begin
```

只门控写使能，没有复位值 → 复位后 **sp(x2) 是未定义值**。

| 程序类型 | 要不要设 sp |
|---|---|
| 纯汇编，只有一层 `jal`/`ret`，不碰栈（如 `blink.S`） | 可以不设 |
| 有嵌套函数调用 / 用 C 编译 | **必须设**，否则压栈踩飞 |

`crt0.S` 做的事：

```asm
_start:
    li    sp, 0x2000      # 栈顶 = RAM 末尾（RAM 是 0x0000~0x1FFF）
    li    gp, 0x1800      # 全局指针
    call  main
1:  j     1b              # main 返回就停住
```

栈从 `0x2000` 往下长，最高用到 `0x1FFC`。

### ⚠️ 已知限制：不清 .bss

当前 `link.ld` 没有定义 `__bss_start` / `_end` 符号，`crt0.S` 也就不清 `.bss`。
**C 里的未初始化全局变量不保证是 0**：

```c
int counter;              /* ❌ 可能不是 0 */
static int counter = 0;   /* ✅ 有初值，会进 .data */
```

## 6. 链接脚本 link.ld

`ENTRY(_start)`，`.text` 放在 **`0x00000000`**。

**起始地址必须是 0**：下载器把数据直接写进 RAM[0..]，BOOT ROM 复位后从 `0x0` 取指。
`.text.start` 必须排在最前，保证 `_start` 落在地址 0。没有 MMU，全部走物理地址。

---

# 第二部分：接口地址

## 7. 地址空间总览

XT_HB 是 15 位地址，高 3 位 `addr[14:12]` 是设备 ID：

| 地址范围 | 段 | 说明 |
|---|---|---|
| `0x0000 ~ 0x1FFF` | **RAM** | 8 KB（2048 × 32 bit），代码和数据都在这 |
| `0x2000 ~ 0x2FFF` | **HB32** | 系统外设（见下表） |
| `0x3000 ~ 0x3FFF` | **WISHBONE** | 原 EFB 段，现在是 `Null_Device`，读全 0 |
| `0x4000 ~ 0x7FFF` | **XT_LB** | 低速外设：按键 / LED / 数码管 |

## 8. HB32 系统外设（基址 0x2000 + 设备号 × 0x20）

| 地址 | 设备 | 寄存器 | 说明 |
|---|---|---|---|
| **0x2000** | BOOT_CTRL | w0 配置 | **读**：`bit0` = K1 按下（1=按下），`bit1` = RAM 模式按钮<br>**写**：`0x00` = 切到 RAM 模式并复位；`0x55` = 切回 ROM 模式并复位 |
| | | w1 字符串地址 | 预加载字符串指针 |
| | | w2 字符串数据 | 读一次自动 +1 |
| **0x2020** | EINT_CTRL | w0 中断使能 | 每位对应一个 `irq_source[i]` |
| | | w1 待处理中断 | 只读，`irq_source & enable` |
| **0x2040** | SYSTEM_TIMER | w0 `mtimel` | 计时器低 32 位 |
| | | w1 `mtimeh` | 计时器高 32 位 |
| | | w2 `mtimecmpl` | 比较值低 32 位，**写入自动清中断** |
| | | w3 `mtimecmph` | 比较值高 32 位 |
| **0x2060** | UART | w0 | **写 = 发送字节**（bit7:0）<br>**读 = 接收字节**（读操作自动清 RX 中断） |
| | **0x2064** | w1 状态 | `bit0` = tx_ready（发送缓冲未满）<br>`bit1` = **rx_not_empty（有数据可读）**<br>`bit2` = tx_empty（发送缓冲空）<br>`bit3` = rx_full（接收缓冲满） |
| **0x2080** | SOFTWARE_INT | w0 `msip` | 写 1 触发软件中断，写 0 清除 |
| **0x20A0** | GPIO | w0 `DIR` | 1 = 输出，0 = 输入。**复位全 0（全输入）** |
| | **0x20A4** | w1 `DATA` | 写 = 输出值，读 = 引脚实际电平 |
| | **0x20A8** | w2 `AF_EN` | 复用功能使能，默认 0 = 普通 GPIO |
| | **0x20AC** | w3 `AFL` | gpio[15:0] 的复用选择，每脚 2 bit |
| | **0x20B0** | w4 `AFH` | gpio[29:16] 的复用选择，每脚 2 bit |

### 中断源分配

| 位 | 来源 |
|---|---|
| `irq_source[0]` | UART 接收到数据 |
| `irq_source[31:1]` | 全部接 0（原 EFB 的 I2C/SPI/Timer 已删除） |

## 9. XT_LB 低速外设（基址 0x4000 + 设备号 × 0x40）

| 地址 | 设备 | 寄存器 | 说明 |
|---|---|---|---|
| **0x4000** | SW_KEY | w0 按键 | 已取反，**bit0 = 1 表示 K1 按下**；bit3:1 恒 0 |
| **0x4001** | | w1 拨码开关 | 本板 `sw_raw` 固定 `3'b111`，读恒为 7 |
| **0x4080** | LED | w0 | 写低 8 位。top 只引出 `led[1:0]` → **W13 / W14**。复位值 `0xFF`，所以**上电两灯都亮** |
| **0x40C0** | LEDSD | w0 `display_data` | 数码管数据（EBAZ4205 没有数码管，接哑信号） |
| **0x40C1** | | w1 `ledsd_control` | 数码管控制 |

> 读拨码开关要用 `lbu`（字节读），因为该外设判断的是地址 bit0。

## 10. 引脚对照

| 端口 | 引脚 | 备注 |
|---|---|---|
| `led[0]` | **W14** | 板载 LED |
| `led[1]` | **W13** | 板载 LED |
| `rst_btn` | **U20** | 复位按钮，低有效，内部上拉 |
| `key_download` | **V20** | K1，低有效（按下接地），内部上拉 |
| `uart_tx` | U19 | 已不使用（PS 侧走 AXI UART Lite） |
| `gpio[0]~[29]` | L17 L16 K19 K18 K17 J20 J19 J18 H20 H18 H17 H16 G20 G19 F20 F19 E19 D20 L19 L20 M17 M18 M19 M20 N17 N20 P18 P19 P20 R18 | 全部已约束 |

---

# 第三部分：C 程序怎么用这些地址

## 11. 核心写法：`volatile` 指针

```c
#define REG32(addr)  (*(volatile unsigned int *)(addr))
```

**三个要点缺一不可：**

| 要素 | 为什么 |
|---|---|
| `volatile` | 告诉编译器「这个值随时会被硬件改」，**禁止缓存和优化**。不加的话 `while (UART_STAT & 2);` 会被优化成死循环或直接删掉 |
| 强制类型转换 | 地址是整数，要转成 `volatile unsigned int *` 才能解引用 |
| 解引用 `*` | `*(...)` 表示「访问这个地址」 |

## 12. 完整的外设宏定义

```c
#ifndef SOC_IO_H
#define SOC_IO_H

#define REG32(addr)   (*(volatile unsigned int  *)(addr))
#define REG8(addr)    (*(volatile unsigned char *)(addr))

/* ---- 自举控制 0x2000 ---- */
#define BOOT_CTRL       REG32(0x2000)   /* 读 bit0=K1按下; 写 0x00=RAM模式复位, 0x55=ROM模式复位 */

/* ---- 外部中断 0x2020 ---- */
#define EINT_ENABLE     REG32(0x2020)   /* 中断使能，每位对应 irq_source[i] */
#define EINT_PENDING    REG32(0x2024)   /* 待处理中断（只读） */

/* ---- 系统计时器 0x2040 ---- */
#define MTIME_LO        REG32(0x2040)
#define MTIME_HI        REG32(0x2044)
#define MTIMECMP_LO     REG32(0x2048)   /* 写入自动清中断 */
#define MTIMECMP_HI     REG32(0x204C)

/* ---- UART 0x2060 ---- */
#define UART_DATA       REG32(0x2060)   /* 写=发送, 读=接收(自动清中断) */
#define UART_STAT       REG32(0x2064)
#define UART_TX_READY   (1u << 0)       /* 发送缓冲未满 */
#define UART_RX_READY   (1u << 1)       /* 有数据可读 */
#define UART_TX_EMPTY   (1u << 2)       /* 发送缓冲空 */
#define UART_RX_FULL    (1u << 3)       /* 接收缓冲满 */

/* ---- 软件中断 0x2080 ---- */
#define MSIP            REG32(0x2080)   /* 写 1 触发，写 0 清除 */

/* ---- GPIO 0x20A0 ---- */
#define GPIO_DIR        REG32(0x20A0)   /* 1=输出, 0=输入 */
#define GPIO_DATA       REG32(0x20A4)   /* 写=输出, 读=输入 */
#define GPIO_AF_EN      REG32(0x20A8)
#define GPIO_AFL        REG32(0x20AC)
#define GPIO_AFH        REG32(0x20B0)

/* ---- 低速外设 0x4000 ---- */
#define KEY_REG         REG32(0x4000)   /* bit0 = K1 按下 */
#define SWITCH_REG      REG8 (0x4001)
#define LED             REG32(0x4080)   /* 低 8 位, top 只引出 led[1:0] */
#define LEDSD_DATA      REG32(0x40C0)
#define LEDSD_CTRL      REG32(0x40C4)

#endif
```

## 13. 典型用法

### LED 闪灯

```c
#include "soc_io.h"

static void delay(volatile unsigned n) {   /* volatile 必须有，否则被优化掉 */
    while (n--) ;
}

int main(void) {
    for (;;) {
        LED = 0b01;          /* W14 亮 */
        delay(200000);
        LED = 0b10;          /* W13 亮 */
        delay(200000);
    }
}
```

### UART 发送（带等待，不会丢字节）

```c
void uart_putc(char c) {
    while (!(UART_STAT & UART_TX_READY))   /* 等发送缓冲有空位 */
        ;
    UART_DATA = (unsigned char)c;
}

void uart_puts(const char *s) {
    while (*s) uart_putc(*s++);
}

/* 用法 */
uart_puts("Hello\r\n");
```

**不要不检查就直接写**：`UART_BUS` 的发送 FIFO 只有 4 字节，猛写会丢数据。

### UART 接收（非阻塞）

```c
int uart_getc(void) {
    if (!(UART_STAT & UART_RX_READY))      /* bit1 = 有数据 */
        return -1;
    return UART_DATA & 0xFF;               /* 读操作自动清中断 */
}
```

⚠️ `UART_BUS` 的 RX 也只有 **4 字节 FIFO**，不读就会溢出（`UART_RX_FULL`）。

### GPIO 输出

```c
void gpio_init(void) {
    GPIO_AF_EN = 0;              /* 关掉复用，当普通 IO 用 */
    GPIO_DIR   = 0x0000FFFF;     /* 低 16 位设为输出 */
}

int main(void) {
    gpio_init();
    GPIO_DATA = 0x000000AA;      /* 输出高低电平 */
    for (;;) {
        GPIO_DATA ^= 0x0000FFFF; /* 全部翻转 */
        delay(100000);
    }
}
```

**顺序很重要**：先写 `DIR` 再写 `DATA`。复位后 `DIR` 全 0 = 全输入，
此时引脚是 `1'bz` 高阻，写 `DATA` 没有任何效果。

### 读按键

```c
if (KEY_REG & 1) {          /* K1 按下 */
    /* ... */
}
```

`KEY_REG` 内部已取反，按下时读到 1。

### 系统计时器（做精确延时）

```c
void delay_ms(unsigned ms) {
    unsigned start = MTIME_LO;
    while ((MTIME_LO - start) < ms * 1000u)   /* 1ms = 1000 tick，跨 32 位溢出先不处理 */
        ;
}
```

> 计时器时钟频率取决于 `SystemTimer` 的 `timer_clk` 输入，用前先确认。

## 14. 常见错误对照

| 现象 | 原因 |
|---|---|
| `while (UART_STAT & 2);` 卡死不动 | 少了 `volatile`，编译器把读优化成了一次 |
| 写 `GPIO_DATA` 没反应 | 没先写 `GPIO_DIR`，引脚还是高阻 |
| LED 闪得看不清 | 延时变量没加 `volatile`，循环被 `-O2` 删了 |
| UART 发出来是乱码 | 波特率不对。`baud = sampling_clk / 8`，当前 19200 |
| UART 丢字节 | 没检查 `UART_TX_READY` 就连续写，4 字节 FIFO 溢出 |
| 程序跑飞 | 没设 sp（C 程序必须配 `crt0.S`） |
| 全局变量初值不是 0 | `.bss` 没清，见第 5 节 |
| `undefined reference to '__mulsi3'` | 漏了 `-lgcc` |
| 下载报失败 | `app.bin` 超过 7680 字节 |

---

# 第四部分：上板

## 15. 下载流程

```bash
# 前提：板子刚重启过（网口通）。加载过 bitstream 后网口会断，要传文件必须先重启

# ① 传文件
scp app.bin root@192.168.100.1:/lib/firmware/

# ② 串口登录后加载 PL（这一步之后网口会断，正常现象）
echo top_wrapper_gpio.bin > /sys/kernel/pl/load

# ③ 下载程序，看到三行 "==> 匹配" 全绿即成功
./pl_dl /lib/firmware/app.bin

# ④ 按 U20 复位按钮 → 程序开始跑
```

`pl_dl` 的输出：

```
发送 'V'         → 匹配 "Len="   ✅
发送块数 N + 'x'  → 匹配 "0x78"  ✅
等 SoC 空转 1.2s
发送 xxx 字节
发送 'W'         → 匹配 "0x57"  ✅
*** 下载成功 ***
```

任何一步超时会打印 `*** 下载失败 ***` 并返回码 2。

### 复位之后发生了什么

```
U20 复位 → BOOT ROM 从 0x0 开始
  → 读 0x2000（BOOT_CTRL）bit0，判断 K1 是否按下
      ├─ 按下（=1）→ 进下载模式，循环打印 🔓:0x56
      └─ 未按（=0）→ 检查 RAM[0]
            ├─ RAM[0] == 0 → 跳 0x74 → LED 闪灯循环（表示没程序）
            └─ RAM[0] != 0 → 写 0x00 到 BOOT_CTRL
                             → 切到 RAM 模式 + 自动复位
                             → 从 0x0 执行刚下载的程序
```

所以下载成功后按 U20，ROM 会发现 RAM 里有程序，自动切 RAM 模式并再复位一次。

## 16. 一句话备忘

```bash
export PATH=/d/vivado/2026.1/gnu/riscv/nt/bin:$PATH
cd RISC_v_Bisac_User/sw
riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -O2 \
    -nostdlib -nostartfiles -ffreestanding \
    -T link.ld -o app.elf crt0.S app.c -lgcc
riscv64-unknown-elf-objcopy -O binary app.elf app.bin
ls -l app.bin     # ≤ 7680
```
