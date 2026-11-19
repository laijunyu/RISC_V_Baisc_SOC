# 闪灯 + UART 测试程序 (RV32I)
#
# 用途: 验证 UART 下载流程是否走通
#   1. 上电从 RAM 0x0 开始执行
#   2. 通过 UART 发送 "OK\n" —— 串口能看到就说明 CPU 在跑
#   3. 两个 LED 交替闪 (0x4080, EBAZ4205 上只有 led[1:0] 引出)
#
# 地址映射 (XT_HB 低 15 位):
#   LED   : 0x4080  写低 8 位
#   UART  : 0x2060  写=发送, 读=接收
#   UART状态: 0x2064 bit1=RX有数据
#
# 编译:
#   riscv64-unknown-elf-as -march=rv32i -mabi=ilp32 -o blink.o blink.S
#   riscv64-unknown-elf-ld -T link.ld -o blink.elf blink.o
#   riscv64-unknown-elf-objcopy -O binary blink.elf blink.bin

    .section .text
    .globl _start

_start:
    # s0 = 0x2060 (UART)
    lui   s0, 0x2
    addi  s0, s0, 0x60
    # s1 = 0x4080 (LED)
    lui   s1, 0x4
    addi  s1, s1, 0x80

    # ---- 发 "OK\n" ----
    li    a0, 79            # 'O'
    sw    a0, 0(s0)
    jal   ra, delay_short

    li    a0, 75            # 'K'
    sw    a0, 0(s0)
    jal   ra, delay_short

    li    a0, 10            # '\n'
    sw    a0, 0(s0)
    jal   ra, delay_short

    # ---- 两灯交替 ----
    li    t1, 1             # led[0] 亮
blink:
    sw    t1, 0(s1)
    jal   ra, delay_long
    xori  t1, t1, 3         # 01 <-> 10 交替
    j     blink

# ---- 短延时: 约 5ms (20000*3/12MHz) ----
delay_short:
    li    t2, 20000
1:  addi  t2, t2, -1
    bnez  t2, 1b
    ret

# ---- 长延时: 约 0.5s (2000000*3/12MHz) ----
delay_long:
    li    t2, 2000000
1:  addi  t2, t2, -1
    bnez  t2, 1b
    ret
